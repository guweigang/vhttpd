module host

import app_bundle
import crypto.sha256
import encoding.base64
import json2 as json
import os
import runtime_upgrade
import time

pub type ApplicationDeploymentPreview = runtime_upgrade.DeploymentPreview
pub type ApplicationDeploymentStatus = runtime_upgrade.DeploymentStatus

fn (mut s ServerSession) discard_deployment() ! {
	if s.pending_deployment.id == '' { return }
	if s.state.deployments.any(!it.finished()) {
		return error('部署正在远端执行，不能删除恢复文件。')
	}
	path := os.join_path(os.dir(s.pending_deployment.config_path), '.desktop-deployments', s.pending_deployment.id)
	s.shell('set -eu\np=' + shell_quote(path) + '\n[ ! -L "$p" ] && rm -rf -- "$p"\n', 5000)!
	s.pending_deployment = runtime_upgrade.DeploymentRequest{}
	s.state = ServerSnapshot{ ...s.state, deployment_preview: ApplicationDeploymentPreview{} }
}

fn (mut s ServerSession) prepare_application(command ServerCommand) ! {
	s.inspect()!
	if s.state.upgrades.any(!it.finished()) || s.state.deployments.any(!it.finished()) {
		return error('远端正在升级或部署，请等待操作完成。')
	}
	matches := s.state.projects.filter(it.id == command.project_id)
	if matches.len != 1 { return error('请选择目标服务器上的实例。') }
	p := matches[0]
	if p.config_path != os.join_path(s.state.root, 'instances', p.name, 'vhttpd.toml') || p.runtime_id == '' {
		return error('当前仅支持工作台管理的 SSH 手工实例。')
	}
	runtime := select_remote_runtime(s.state.runtimes, p.runtime_id)!
	protocol := s.shell(shell_quote(runtime.path + '/vhttpd') + ' --workbench-deploy-version', 8000) or { return error('目标运行包尚不支持应用部署。请先在运行环境升级到支持应用部署的新版，再重试。') }
	if protocol.trim_space() != '1' {
		return error('远端应用部署协议不兼容，请先升级运行包。')
	}
	s.discard_deployment()!
	mut manager := &RemoteManager{}
	manager.connect_with_session(p, '', s.state.control_path)!
	defer {
		manager.disconnect()
		for endpoint in manager.browser_endpoints {
			mut server := endpoint.server
			server.stop()
		}
	}
	instance := json.decode[RemoteInstance](manager.request(.get, '/admin/workbench/instance', '')!.body)!
	if !instance.ready || !instance.manual_restart || instance.disk_revision == '' || instance.disk_revision != instance.effective_revision {
		return error('请先让目标实例业务就绪、配置全部生效，再部署应用。')
	}
	id := new_remote_id()!
	payload := app_bundle.collect(command.local_project.workdir, command.local_project.config_path, id) or { return error(application_deployment_hint(err.msg())) }
	text := json.encode(app_bundle.Payload{ ...payload, fingerprint: '' })
	request := runtime_upgrade.DeploymentRequest{ id: id, server_root: s.state.root, config_path: p.config_path, runtime_id: p.runtime_id, admin_port: p.admin_port, token: p.token, expected_boot: instance.boot_id, expected_revision: instance.effective_revision, payload_hash: sha256.hexhash(text) }
	local := os.join_path(os.temp_dir(), 'vh-application-' + id)
	os.mkdir(local, mode: 0o700)!
	defer { os.rmdir_all(local) or {} }
	archive := os.join_path(local, 'payload.json')
	write_project_contents(create_project_file(archive)!, text)!
	dir := os.join_path(os.dir(p.config_path), '.desktop-deployments', id)
	s.shell('set -eu\numask 077\np=' + shell_quote(os.dir(p.config_path)) + '\n[ ! -L "$p/.desktop-deployments" ]\nmkdir -p "$p/.desktop-deployments"\nmkdir -m 700 ' + shell_quote(dir) + '\n', 5000)!
	mut prepared := false
	defer { if !prepared { s.shell('rm -rf -- ' + shell_quote(dir), 3000) or {} } }
	mut args := ['-O', '-o', 'ControlPath=' + s.directory + '/control', '-o', 'ControlMaster=no',
		'-o', 'BatchMode=yes', '-o', 'ProxyCommand=false']
	if s.server.ssh_port > 0 { args << ['-P', s.server.ssh_port.str()] }
	destination := if s.server.ssh_user == '' {
		s.server.ssh_host
	} else {
		s.server.ssh_user + '@' + s.server.ssh_host
	}
	// All paths are quoted for legacy scp's remote shell; no password is an argument.
	args << [archive, destination + ':' + shell_quote(dir + '/payload.json')]
	s.job.command(s.scp_executable, args, 120000)!
	script := 'set -eu\numask 077\nprintf %s ' + shell_quote(base64.encode_str(json.encode(request))) + ' | base64 -d > ' + shell_quote(dir + '/request.json') + '\n' + shell_quote(runtime.path + '/vhttpd') + ' --workbench-deploy-prepare ' + shell_quote(dir + '/request.json')
	response := s.shell_limited(script, 30000, 8 * 1024 * 1024) or { return error('远端整项目部署预检失败：请检查监听绑定、远端认证配置和本地入口文件。原实例仍在运行。') }
	preview := json.decode[ApplicationDeploymentPreview](response.trim_space()) or { return error('部署预览无效，未停止目标实例。') }
	if preview.id != id || preview.config_path != p.config_path {
		return error('部署目标发生变化，请重新预览。')
	}
	prepared = true
	s.pending_deployment = request
	s.deployment_local_project = command.local_project
	s.deployment_fingerprint = payload.fingerprint
	s.state = ServerSnapshot{ ...s.state, deployment_preview: preview, message: '预检通过。源码、静态资源和 include 将一起部署；监听端口与认证沿用远端。' }
}

fn (mut s ServerSession) deploy_application(command ServerCommand) ! {
	r := s.pending_deployment
	if r.id == '' || command.deployment_id != r.id {
		return error('部署预览已失效，请重新预览。')
	}
	payload := app_bundle.collect(s.deployment_local_project.workdir, s.deployment_local_project.config_path, r.id) or { return error(application_deployment_hint(err.msg())) }
	if payload.fingerprint != s.deployment_fingerprint {
		return error('本地项目在预览后发生变化，请重新预览后部署。')
	}
	runtime := select_remote_runtime(s.state.runtimes, r.runtime_id)!
	dir := os.join_path(os.dir(r.config_path), '.desktop-deployments', r.id)
	status := ApplicationDeploymentStatus{ id: r.id, config_path: r.config_path, phase: 'validating' }
	script := 'set -eu\numask 077\nstatus=' + shell_quote(base64.encode_str(json.encode(status))) + '\nproject=' + shell_quote(os.dir(r.config_path)) + '\nid=' + shell_quote(r.id) + '\ndir=' + shell_quote(dir) + '\nrequest=' + shell_quote(base64.encode_str(json.encode(r))) + '\nbinary=' + shell_quote(runtime.path + '/vhttpd') + '\n' + $embed_file('remote_scripts/deploy.sh').to_string()
	s.state = ServerSnapshot{ ...s.state, deployment_preview: ApplicationDeploymentPreview{}, deployments: s.state.deployments.filter(it.config_path != r.config_path), message: '部署已交由远端执行。短暂停机后自动检查整项目生效；失败时恢复原应用。' }
	mut statuses := s.state.deployments.clone()
	statuses << status
	s.state = ServerSnapshot{ ...s.state, deployments: statuses }
	s.pending_deployment = runtime_upgrade.DeploymentRequest{}
	s.shell(script, 8000) or {
		s.state = ServerSnapshot{ ...s.state, message: '部署提交结果待确认，远端可能已开始执行；重新连接查看结果，不会重复提交。' }
		return
	}
}

fn (mut s ServerSession) poll_deployments() ! {
	mut statuses := []ApplicationDeploymentStatus{}
	mut completed := false
	for prior in s.state.deployments {
		if prior.finished() {
			statuses << prior
			continue
		}
		path := os.join_path(os.dir(prior.config_path), '.desktop-deployments', prior.id, 'status.json')
		raw := s.shell('set -eu\np=' + shell_quote(path) + '\n[ ! -L "$p" ] && [ -f "$p" ] && [ "$(wc -c < "$p")" -le 16384 ]\nbase64 < "$p"', 5000)!
		status := json.decode[ApplicationDeploymentStatus](base64.decode_str(raw.replace('\n', '')))!
		if status.id != prior.id || status.config_path != prior.config_path {
			return error('部署状态不匹配，请重新连接服务器。')
		}
		if status.finished() { completed = true }
		statuses << status
	}
	s.state = ServerSnapshot{ ...s.state, deployments: statuses }
	if completed { s.discover_projects()! }
	s.next_deployment_probe = time.ticks() + 1500
}

pub fn application_deployment_title(status ApplicationDeploymentStatus) string {
	return match status.phase {
		'validating' { '正在检查部署条件' }
		'stopping' { '正在停止原应用' }
		'switching' { '正在切换源码、资源与 include' }
		'starting' { '正在启动并检查整项目生效' }
		'rolling_back' { '部署失败，正在恢复原应用' }
		'completed' { '部署成功 · 整项目已生效' }
		'rolled_back' { '部署失败 · 原应用已恢复' }
		'rollback_failed' { '恢复未完成 · 请检查远端日志' }
		else { '部署未完成 · 原应用未切换或需要检查' }
	}
}

pub fn application_deployment_hint(reason string) string {
	return match reason {
		'' { '' }
		'project_root_required' {
			'配置入口需位于本地项目工作目录。请重新选择项目根目录。'
		}
		'deployment_requires_v2' { '应用部署目前支持 version = 2 的项目。' }
		'include_outside_project', 'project_symlink_not_supported', 'unsafe_bundle_path',
		'absolute_application_path', 'entry_not_in_bundle' {
			'项目包含越界来源、绝对应用路径或符号链接，请整理为项目目录内的相对路径后重试。'
		}
		'application_bundle_too_large' {
			'应用包超过首版限制（64 MiB、4096 个文件、单文件 16 MiB），请精简构建产物。'
		}
		'listener_mapping_required' {
			'本地与远端的监听标识和协议需一致。请先在远端配置监听，端口与认证将沿用远端。'
		}
		'remote_credential_required' {
			'应用需要新的认证配置，请先在远端 Admin UI 配置，避免上传本地凭据。'
		}
		'deployment_preview_stale', 'instance_not_effective' {
			'目标实例或文件已变化，请完成配置生效并重新预览。'
		}
		'startup_or_effectiveness_timeout', 'new_process_exited' {
			'新应用未能启动或就绪，已尝试恢复原应用；请核对部署结果和日志。'
		}
		else {
			'请检查项目来源、完整 include 及远端运行日志，然后重新预览部署。'
		}
	}
}
