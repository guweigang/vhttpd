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
	fingerprint string
	payload     app_bundle.Payload
	before      []ComponentBefore
}

pub fn (mut m Manager) preview_component(source Project, component string) ! {
	m.component_preview = ApplicationDeploymentPreview{}
	m.pending_component = none
	if m.phase in [.starting, .stopping] { return error('请等待运行环境操作完成。') }
	id := new_remote_id()!
	p := app_bundle.collect_component(source.workdir, source.config_path, id, component)!
	composed := app_bundle.compose_component(p, m.project.config_path)!
	mut before := []ComponentBefore{}
	mut views := []app_bundle.FileView{}
	for file in composed.files {
		path := app_bundle.safe_target(m.project.workdir, file.path)!
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
			action: if !exists {
				'add'
			} else if sha256.sum(bytes).hex() == file.hash {
				'unchanged'
			} else {
				'replace'
			}
			size:   base64.decode(file.data).len
		}
	}
	m.pending_component = PendingComponent{ source: source, component: component, fingerprint: p.fingerprint, payload: composed, before: before }
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
		if m.phase == .running {
			mut request := http.Request{ url: m.info.admin_url.replace('/admin/ui/', '/admin/workbench/instance'), read_timeout: 500 * time.millisecond, write_timeout: 500 * time.millisecond, max_retries: 1, disable_connection_reuse: true }
			request.add_custom_header('x-vhttpd-admin-token', m.token)!
			if response := request.do() {
				if response.status_code == 200 {
					instance := json.decode[RemoteInstance](response.body)!
					if instance.startup_failed() || instance.error in [
						'executor_warmup_failed',
						'whole_project_invalid',
					] {
						return error('新应用初始化失败。')
					}
					if instance.ready && instance.disk_revision != '' && instance.disk_revision == instance.effective_revision {
						return
					}
				}
			}
		}
		time.sleep(80 * time.millisecond)
	}
	return error('运行环境尚未全部就绪，安装验证超时。')
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
	current := app_bundle.collect_component(p.source.workdir, p.source.config_path, preview, p.component)!
	if current.fingerprint != p.fingerprint {
		return error('应用源码已变化，请重新预览。')
	}
	// Re-run composition to catch newly added includes and resource changes.
	composed := app_bundle.compose_component(current, m.project.config_path)!
	if composed.files != p.payload.files {
		return error('运行环境已变化，请重新预览。')
	}
	lock_dir := os.join_path(m.project.workdir, '.desktop-runtime-lock')
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
		if before.exists && sha256.sum(before.bytes).hex() == file.hash { continue }
		app_bundle.safe_target(project.workdir, file.path) or {
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
			app_bundle.safe_target(project.workdir, file.path)!
			if sha256.sum(os.read_bytes(before.path)!).hex() != file.hash {
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
			mut dir := os.dir(os.join_path(project.workdir, file.path))
			for dir.starts_with(os.join_path(project.workdir, 'apps', p.component)) {
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
	m.message = '应用 ${p.component} 已独立安装；环境配置、共享资源及其他应用保留。'
	m.log(m.message)
}
