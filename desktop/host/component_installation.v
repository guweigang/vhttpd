module host

import app_bundle
import crypto.sha256
import encoding.base64
import os
import net
import net.http
import json2 as json
import time

struct ComponentBefore {
	path   string
	exists bool
	bytes  []u8
	mode   int
}

struct PendingComponent {
	source      Project
	component   string
 installation_id string
 adopt_engines []string
	fingerprint string
	payload     app_bundle.Payload
	before      []ComponentBefore
}

pub fn (mut m Manager) preview_component(source Project, component string) ! {
 m.preview_component_target(source,component,'')!
}

pub fn (mut m Manager) preview_component_target(source Project, component string, installation_id string) ! {
 m.preview_component_mode(source,component,installation_id,[])!
}

pub fn (mut m Manager) preview_component_mode(source Project, component string, installation_id string, adopt_engines []string) ! {
	m.component_preview = ApplicationDeploymentPreview{}
	m.pending_component = none
	if m.phase in [.starting, .stopping] { return error('请等待运行环境操作完成。') }
	id := new_remote_id()!
	p := if adopt_engines.len > 0 {app_bundle.collect_component_adoption(source.workdir,source.config_path,id,component,adopt_engines)!} else if installation_id == '' { app_bundle.collect_component(source.workdir, source.config_path, id, component)! } else { app_bundle.collect_component_update(source.workdir, source.config_path, id, component,installation_id)! }
	composed := app_bundle.compose_component(p, m.project.config_path)!
	mut before := []ComponentBefore{}
	mut views := []app_bundle.FileView{}
	for file in composed.files {
		path := app_bundle.safe_target(os.dir(m.project.config_path), file.path)!
		exists := os.exists(path)
		if exists && (!os.is_file(path) || os.file_size(path) > 16 * 1024 * 1024) {
			return error('目标文件冲突。')
		}
		bytes := if exists { os.read_bytes(path)! } else { []u8{} }
		before << ComponentBefore{
			path:   path
			exists: exists
			bytes:  bytes
			mode:   if exists {
				int(os.stat(path)!.mode & 0o777)
			} else {
				0
			}
		}
		views << app_bundle.FileView{
			path:   file.path
			action: if file.remove {
                'delete'
            } else if !exists {
				'add'
			} else if sha256.sum(bytes).hex() == file.hash {
				'unchanged'
			} else {
				'replace'
			}
			size:   base64.decode(file.data).len
		}
	}
	m.pending_component = PendingComponent{ adopt_engines:adopt_engines.clone(), installation_id:installation_id, source: source, component: component, fingerprint: p.fingerprint, payload: composed, before: before }
	m.component_preview = ApplicationDeploymentPreview{
		id:          id
		config_path: m.project.config_path
		files:       views
		preserved:   [
			'environment',
			'resources',
			'other-applications',
		]
	}
}

fn (mut m Manager) installation_stop() ! {
	m.stop()
	deadline := time.ticks() + m.stop_timeout + 2000
	for !isnil(m.process) && time.ticks() < deadline {
		m.tick()
		time.sleep(30 * time.millisecond)
	}
	if !isnil(m.process) {
		return error('运行环境尚未停止；请在运行环境页处理，安装没有继续写文件。')
	}
}

fn (mut m Manager) installation_ready() ! {
	deadline := time.ticks() + m.start_timeout + m.stop_timeout
	for time.ticks() < deadline {
		m.tick()
		if isnil(m.process) || m.phase in [.failed, .stopped] {
			return error('新应用启动失败。')
		}
		if m.installation_ready_now()! {
			return
		}
		time.sleep(80 * time.millisecond)
	}
	return error('运行环境尚未全部就绪，安装验证超时。')
}

fn (m &Manager) installation_ready_now() !bool {
	if m.phase != .running {
		return false
	}
	mut request := http.Request{ url: m.info.admin_url.replace('/admin/ui/', '/admin/workbench/instance'), read_timeout: 500 * time.millisecond, write_timeout: 500 * time.millisecond, max_retries: 1, disable_connection_reuse: true }
	request.add_custom_header('x-vhttpd-admin-token', m.token)!
	response := request.do() or { return false }
	if response.status_code != 200 {
		return false
	}
	instance := json.decode[RemoteInstance](response.body)!
	if instance.startup_failed() || instance.error in ['executor_warmup_failed', 'whole_project_invalid'] {
		return error('新应用初始化失败。')
	}
	return instance.ready && instance.disk_revision != '' && instance.disk_revision == instance.effective_revision
}

fn component_verify_before(items []ComponentBefore) ! {
	for item in items {
		if os.is_link(item.path) || os.exists(item.path) != item.exists {
			return error('安装预览已过期，请重新预览。')
		}
		if item.exists && (os.read_bytes(item.path)! != item.bytes || int(os.stat(item.path)!.mode & 0o777) != item.mode) {
			return error('安装预览后配置发生变化，请重新预览。')
		}
	}
}

fn component_write(path string, bytes []u8, mode int) ! {
	os.mkdir_all(os.dir(path), mode: 0o700)!
	temp := path + '.install-' + new_remote_id()!
	defer { os.rm(temp) or {} }
	write_project_contents(create_project_file(temp)!, bytes.bytestr())!
	os.chmod(temp, mode)!
	os.mv(temp, path)!
}

pub fn (mut m Manager) install_component(preview string, binary string) ! {
	if isnil(m.process) {
		info := inspect_project(m.project)!
		mut guard := net.listen_tcp(.ip, '${url_host(info.admin_host)}:${info.admin_port}') or { return error('该运行环境的管理端口正在使用，不能作为停止环境安装。请先通过拥有它的进程管理入口处理。') }
		defer { guard.close() or {} }
		m.apply_component(preview, binary)!
		return
	}
	m.apply_component(preview, binary)!
}

fn (mut m Manager) apply_component(preview string, binary string) ! {
	p := m.pending_component or { return error('请先预览应用安装。') }
	if preview != m.component_preview.id || m.component_preview.config_path != m.project.config_path {
		return error('安装目标已变化，请重新预览。')
	}
	current := if p.adopt_engines.len > 0 {app_bundle.collect_component_adoption(p.source.workdir,p.source.config_path,preview,p.component,p.adopt_engines)!} else if p.installation_id == '' { app_bundle.collect_component(p.source.workdir, p.source.config_path, preview, p.component)! } else { app_bundle.collect_component_update(p.source.workdir,p.source.config_path,preview,p.component,p.installation_id)! }
	if current.fingerprint != p.fingerprint {
		return error('应用源码已变化，请重新预览。')
	}
	// Re-run composition to catch newly added includes and resource changes.
	composed := app_bundle.compose_component(current, m.project.config_path)!
	if composed.files != p.payload.files {
		return error('运行环境已变化，请重新预览。')
	}
	lock_dir := os.join_path(os.dir(m.project.config_path), '.desktop-runtime-lock')
	os.mkdir(lock_dir, mode: 0o700) or { return error('另一运行环境操作正在进行，请稍后重试。') }
	defer { os.rmdir(lock_dir) or {} }
	component_verify_before(p.before)!
	was_running := !isnil(m.process)
	project := m.project
	if was_running { m.installation_stop()! }
	component_verify_before(p.before) or {
		if was_running {
			m.start(project, binary)!
			m.installation_ready()!
		}
		return err
	}
	mut changed := []int{}
	mut installed := false
	defer {
		m.pending_component = none
		m.component_preview = ApplicationDeploymentPreview{}
	}
	mut failure := ''
	for i, file in p.payload.files {
		before := p.before[i]
		component_verify_before([before]) or {
			failure = err.msg()
			break
		}
		if before.exists && !file.remove && sha256.sum(before.bytes).hex() == file.hash { continue }
        if file.remove {
            if before.exists { os.rm(before.path) or {failure=err.msg();break}; changed << i }
            continue
        }
		app_bundle.safe_target(os.dir(project.config_path), file.path) or {
			failure = err.msg()
			break
		}
		component_write(before.path, base64.decode(file.data), if before.exists {
			before.mode
		} else {
			file.mode
		}) or {
			failure = err.msg()
			break
		}
		changed << i
	}
	if failure == '' && was_running {
		m.start(project, binary) or { failure = err.msg() }
		if failure == '' { m.installation_ready() or { failure = err.msg() } }
	}
	installed = failure == ''
	if !installed {
		if !isnil(m.process) { m.installation_stop()! }
		changed.reverse_in_place()
		for i in changed {
			before := p.before[i]
			file := p.payload.files[i]
			app_bundle.safe_target(os.dir(project.config_path), file.path)!
			if (file.remove && os.exists(before.path)) || (!file.remove && sha256.sum(os.read_bytes(before.path)!).hex() != file.hash) {
				return error('安装文件被外部修改，已停止恢复以保留现场。')
			}
			if before.exists {
				component_write(before.path, before.bytes, before.mode)!
			} else {
				os.rm(before.path)!
			}
		}
		// Remove only empty directories created for this component.
		for file in p.payload.files.filter(it.path.starts_with('apps/' + p.component + '/')) {
			mut dir := os.dir(os.join_path(os.dir(project.config_path), file.path))
			for dir.starts_with(os.join_path(os.dir(project.config_path), 'apps', p.component)) {
				os.rmdir(dir) or { break }
				dir = os.dir(dir)
			}
		}
		if was_running {
			m.start(project, binary)!
			m.installation_ready()!
		}
		return error('安装失败，原配置与应用已恢复：' + failure)
	}
	record := app_bundle.read_installation(os.dir(project.config_path),p.component) or { app_bundle.Installation{} }
    if record.id != '' {
        record_application_binding(ApplicationBinding{app_id:record.app_id,installation_id:record.id,source:p.source,config_path:project.config_path,component:p.component,engines:record.engines,operation_id:record.deployment_id,fingerprint:record.fingerprint,version:record.version,phase:'installed'}) or {
            m.message = '应用已安装，但部署关系保存失败：' + err.msg()
            m.log(m.message)
            return
        }
    }
	m.message = '应用 ${p.component} 已独立安装；环境配置、共享资源及其他应用保留。'
	m.log(m.message)
}
