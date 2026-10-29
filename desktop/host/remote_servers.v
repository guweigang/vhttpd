module host

import crypto.rand
import crypto.sha256
import encoding.base64
import json2 as json
import os
import runtime_upgrade
import time

// A server is SSH access, independent of any installed runtime or Admin token.
pub struct RemoteServer {
pub:
	id string
	name string
	ssh_host string
	ssh_user string
	ssh_port int
	identity_file string
	auth_method string = 'key'
}

pub fn (s RemoteServer) validate() ! {
	// Reuse the transport validation without inventing an Admin credential.
	RemoteProfile{id: s.id, name: s.name, ssh_host: s.ssh_host, ssh_user: s.ssh_user,
		ssh_port: s.ssh_port, identity_file: s.identity_file, auth_method: s.auth_method,
		token: 'transport-validation-only'}.validate()!
}

pub fn load_remote_servers() ![]RemoteServer {
	path := os.join_path(workbench_data_dir(), 'remote-servers.json')
	if !os.exists(path) { return []RemoteServer{} }
	if os.is_link(path) || os.file_size(path) > 1048576 { return error('服务器记录无效。') }
	os.chmod(path, 0o600)!
	items := json.decode[[]RemoteServer](os.read_file(path)!)!
	validate_remote_servers(items)!
	return items
}

fn validate_remote_servers(items []RemoteServer) ! {
	if items.len > 128 { return error('最多保存 128 台服务器。') }
	mut ids := map[string]bool{}
	for item in items {
		item.validate()!
		if item.id in ids { return error('服务器编号重复。') }
		ids[item.id] = true
	}
}

pub fn save_remote_servers(items []RemoteServer) ! {
	validate_remote_servers(items)!
	os.mkdir_all(workbench_data_dir())!
	os.chmod(workbench_data_dir(), 0o700)!
	path := os.join_path(workbench_data_dir(), 'remote-servers.json')
	if os.is_link(path) { return error('服务器记录不能是符号链接。') }
	temp := path + '.' + new_remote_id()!
	defer { os.rm(temp) or {} }
	write_project_contents(create_project_file(temp)!, json.encode(items))!
	os.mv(temp, path)!
}

pub enum ServerAction { connect trust disconnect inspect install create start upgrade prepare_deploy deploy discard_deploy shutdown }
pub struct ServerCommand {
pub:
	sequence u64
	action ServerAction
	server RemoteServer
	password string
	host_key_id string
	archive string
	release_tag string
	runtime_id string
	local_project Project
	deployment_id string
	project_id string
	name string
	template string = 'vjsx-http'
	web_port int = 19881
	admin_port int = 2018
}
pub struct RemoteRuntime {
pub:
	id string
	version string
	release_tag string
	path string
}

pub fn (runtime RemoteRuntime) label() string {
	return 'vhttpd ' + runtime.version + if runtime.release_tag != '' { ' · ' + runtime.release_tag } else if runtime.id == 'legacy' { ' · 原有运行包' } else { ' · ' + runtime.id[..if runtime.id.len > 19 { 19 } else { runtime.id.len }] }
}

fn remote_runtime_id_valid(id string) bool {
	return id == 'legacy' || (id.len == 71 && id.starts_with('sha256-') && id[7..].bytes().all(it.is_hex_digit()))
}

pub struct ServerSnapshot {
pub:
	sequence u64
	server RemoteServer
	server_id string
	connected bool
	busy bool
	error bool
	message string
	host_key RemoteHostKey
	host_key_changed bool
	platform string
	root string
	version string
	deployment_preview ApplicationDeploymentPreview
	deployments []ApplicationDeploymentStatus
	upgrades []RemoteRuntimeUpgrade
	runtimes []RemoteRuntime
	release_tag string
	control_path string
	// Creation remains visible until the UI acknowledges it with inspect.
	created RemoteProfile
	projects []RemoteProfile
	discovery_revision u64
	discovery_message string
}
pub struct ServerWorker {
pub:
	commands chan ServerCommand = chan ServerCommand{cap: 8}
	snapshots chan ServerSnapshot = chan ServerSnapshot{cap: 1}
	done chan bool = chan bool{cap: 1}
	job RuntimeJob
}
pub fn new_server_worker() ServerWorker {
	w := ServerWorker{}
	spawn server_supervise(w)
	return w
}

@[heap]
struct ServerSession {
mut:
	ssh_executable string = ssh_tool('ssh')
	scp_executable string = ssh_tool('scp')
	server RemoteServer
	process &os.Process = unsafe { nil }
	prompts &RemoteAskpass = unsafe { nil }
	directory string
 windows_ticket string
 ready_output string
	diagnostics string
	pending_deployment runtime_upgrade.DeploymentRequest
	deployment_local_project Project
	deployment_fingerprint string
	next_deployment_probe i64
	next_upgrade_probe i64
	deadline i64
	state ServerSnapshot
	job RuntimeJob
}

fn (mut s ServerSession) close() {
	if s.pending_deployment.id!='' && s.state.connected { s.discard_deployment() or {} }
	s.pending_deployment=runtime_upgrade.DeploymentRequest{}
	s.deployment_fingerprint=''
	s.deployment_local_project=Project{}
 $if windows { revoke_windows_session(s.windows_ticket) }
 s.windows_ticket = ''
 s.ready_output = ''
	if !isnil(s.prompts) { s.prompts.close(); s.prompts = unsafe { nil } }
	if !isnil(s.process) {
		s.process.signal_term()
		until := time.ticks() + 1000
		for s.process.is_alive() && time.ticks() < until { time.sleep(20 * time.millisecond) }
		if s.process.is_alive() { s.process.signal_kill() }
		s.process.wait()
		s.process.close()
		s.process = unsafe { nil }
	}
	if s.directory != '' { os.rmdir_all(s.directory) or {} }
	s.directory = ''
	s.state = ServerSnapshot{message: '服务器连接已断开；远端实例继续运行。'}
}

fn (s &ServerSession) destination_args() []string {
	mut args := []string{}
	if s.server.ssh_port > 0 { args << ['-p', s.server.ssh_port.str()] }
	if s.server.ssh_user != '' { args << ['-l', s.server.ssh_user] }
	args << s.server.ssh_host
	return args
}

fn (mut s ServerSession) connect(server RemoteServer, password string) ! {
	server.validate()!
	if server.auth_method == 'password' { validate_ssh_password(password)! }
	if server.auth_method == 'key' && server.identity_file != '' && !os.is_file(server.identity_file) { return error('SSH 私钥不存在。') }
	s.close()
	s.server = server
	s.directory = os.join_path($if windows { os.temp_dir() } $else { '/tmp' }, 'vh-host-' + new_remote_id()!)
	os.mkdir(s.directory, mode: 0o700)!
	mut args := ['-N', '-T', '-M', '-S', s.directory + '/control', '-o', 'ControlPersist=no',
		'-o', 'StrictHostKeyChecking=ask', '-o', 'FingerprintHash=sha256', '-o', 'UpdateHostKeys=no',
		'-o', 'ForwardAgent=no', '-o', 'ForkAfterAuthentication=no', '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2']
	 $if windows { args = ['-T', '-o', 'ControlMaster=no', '-o', 'ControlPath=none', '-o','StrictHostKeyChecking=ask', '-o','FingerprintHash=sha256','-o','UpdateHostKeys=no','-o','ForwardAgent=no','-o','ConnectTimeout=8','-o','ServerAliveInterval=10','-o','ServerAliveCountMax=2'] }
 if server.auth_method == 'password' {
		args << ['-o', 'BatchMode=no', '-o', 'PasswordAuthentication=yes', '-o', 'PreferredAuthentications=password', '-o', 'PubkeyAuthentication=no',
			'-o', 'KbdInteractiveAuthentication=no', '-o', 'NumberOfPasswordPrompts=1']
	} else {
		args << ['-o', 'BatchMode=no', '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no']
		if server.identity_file != '' { args << ['-i', server.identity_file] }
	}
	s.prompts = new_remote_prompt_session(password, server.auth_method == 'password', os.user_os() == 'windows')!
 $if windows { s.windows_ticket = register_windows_session(server, s.prompts)! }
	args << s.destination_args()
 $if windows { args << "printf 'VHTTPD_SSH_READY\n'; while :; do sleep 60; done" }
	s.process = os.new_process(s.ssh_executable)
	s.process.set_args(args)
	s.process.set_redirect_stdio()
 $if windows { s.process.create_no_window = true }
	s.process.set_environment(s.prompts.environment())
 $if windows { s.process.set_work_folder(os.dir(os.executable())) }
	s.process.run()
	s.diagnostics = ''
	s.deadline = time.ticks() + 15000
	s.state = ServerSnapshot{server: server, server_id: server.id, busy: true, message: '正在连接服务器；不需要 Admin Token。'}
}

// Mux commands cannot fall back to another SSH authentication when disconnected.
fn (s &ServerSession) mux_args() []string {
	 $if windows { mut args := windows_auth_options(s.server); args.insert(0, '-T'); return args }
 return ['-T', '-S', s.directory + '/control', '-o', 'ControlMaster=no', '-o', 'BatchMode=yes', '-o', 'ProxyCommand=false']
}

fn (s &ServerSession) shell(script string, timeout i64) !string {
	return s.shell_limited(script, timeout, 65536)
}

fn (s &ServerSession) shell_limited(script string, timeout i64, max_output int) !string {
	if !s.state.connected || !s.session_available() { return error('请先连接服务器。') }
	// Bounded scripts fit in the SSH stdin pipe. Secrets never become files or arguments.
	if script.len > 16000 { return error('部署配置过大。') }
	mut child := os.new_process(s.ssh_executable)
	mut args := s.mux_args()
	args << s.destination_args()
	args << '/bin/sh -s'
	child.set_args(args)
 $if windows { child.set_environment(windows_session(s.windows_ticket)!.broker.environment()); child.set_work_folder(os.dir(os.executable())); child.create_no_window = true }
	child.set_redirect_stdio_merged()
	child.use_pgroup = true
	child.run()
	defer { child.close() }
	child.stdin_write(script + '\nexit\n')
	$if !windows {
 os.fd_close(child.stdio_fd[0])
 child.stdio_fd[0] = -1
 }
	until := time.ticks() + timeout
	mut output := ''
	for {
		for _ in 0 .. 8 {
			if !child.is_pending(.stdout) { break }
			output += child.stdout_read()
		}
		if output.len > max_output || time.ticks() > until {
			child.signal_pgkill(); child.signal_kill(); child.wait()
			return error('服务器操作超时或输出过多；请刷新运行环境确认结果。')
		}
		select { _ := <-s.job.cancel { child.signal_pgkill(); child.signal_kill(); child.wait(); return error('操作已取消，请刷新服务器状态。') } else {} }
		if !child.is_alive() { break }
		time.sleep(20 * time.millisecond)
	}
	child.wait()
	for child.is_pending(.stdout) { part := child.stdout_read(); if part == '' { break }; output += part }
	if output.len > max_output { return error('服务器返回数据过多，请缩小项目管理范围。') }
	if child.code != 0 {
		// Raw shell/config output is never rendered: it can contain credentials.
		mut reason := '远端命令失败，请检查服务器权限、磁盘空间和运行包兼容性。'
		for line in output.split_into_lines() {
			if line.starts_with('VHTTPD_ERROR:') && line.len < 220 { reason = line.all_after('VHTTPD_ERROR:') }
		}
		return error(reason)
	}
	return output
}

fn (mut s ServerSession) inspect() ! {
	output := s.shell($embed_file('remote_scripts/inspect.sh').to_string(), 12000)!
	mut platform := ''
	mut root := ''
	mut records := []string{}
	for line in output.split_into_lines() {
		if line.starts_with('VHTTPD_PLATFORM:') { platform = line.all_after(':') }
		if line.starts_with('VHTTPD_ROOT:') { root = base64.decode_str(line.all_after(':')) }
		if line.starts_with('VHTTPD_RUNTIME:') { records << line }
	}
	if platform !in ['linux-amd64', 'linux-arm64'] || !root.starts_with('/') || root.contains('\n') { return error('当前只支持 Linux amd64 / arm64 服务器。') }
	runtimes := parse_remote_runtimes(records, root)!
	first := if runtimes.len > 0 { runtimes[0] } else { RemoteRuntime{} }
	s.state = ServerSnapshot{...s.state, platform: platform, root: root, version: first.version, runtimes: runtimes, release_tag: first.release_tag, error: false, created: RemoteProfile{},
		message: if runtimes.len == 0 { '服务器已连接，尚未安装运行包。先安装，再创建实例。' } else { '运行包已就绪。新建实例时选择版本；下载其他版本不会影响已有实例。' }}
	s.discover_projects()!
}

fn (mut s ServerSession) tick() {
	if isnil(s.process) { return }
 $if windows { for _ in 0 .. 8 { part := s.process.stdout_read(); if part == "" { break }; joined := s.ready_output + part; s.ready_output = if joined.len > 4096 { joined[joined.len-4096..] } else { joined } } }
	for _ in 0 .. 8 { part := s.process.stderr_read(); if part == '' { break }; s.diagnostics = (s.diagnostics + part).limit(16384) }
	if !isnil(s.prompts) {
		select { key := <-s.prompts.challenges { s.state = ServerSnapshot{...s.state, host_key: key, message: '首次连接：请核对并确认主机指纹。'} } else {} }
	}
	if !s.process.is_alive() {
		changed := s.diagnostics.contains('REMOTE HOST IDENTIFICATION HAS CHANGED') || s.diagnostics.contains('REVOKED HOST KEY') || s.diagnostics.contains('POSSIBLE DNS SPOOFING')
		mut fingerprint := ''
		for word in s.diagnostics.fields() { if word.starts_with('SHA256:') { fingerprint = word.trim_right('.'); break } }
		s.close()
		s.state = ServerSnapshot{server_id: s.server.id, error: true, host_key_changed: changed, host_key: RemoteHostKey{fingerprint: fingerprint},
			message: if changed { '主机指纹已变化，连接已阻止；请核对服务器，不会自动覆盖信任记录。' } else { 'SSH 连接失败或已断开。请检查主机、端口及认证信息后重试。' }}
		return
	}
	if s.state.connected {
  if time.ticks() > s.next_upgrade_probe && s.state.upgrades.any(!it.finished()) { s.poll_upgrades() or { s.state = ServerSnapshot{...s.state, error: true, message: '升级仍由远端执行，暂时无法读取结果；请重新连接查看。'}; s.next_upgrade_probe = time.ticks() + 5000 } }
  if time.ticks()>s.next_deployment_probe && s.state.deployments.any(!it.finished()) { s.poll_deployments() or { s.state = ServerSnapshot{...s.state,error:true,message:'部署仍由远端执行，暂时无法读取结果；请重新连接查看。'}; s.next_deployment_probe=time.ticks()+5000 } }
  return
 }
	if s.state.host_key.id != '' { return }
	if s.transport_ready() {
		s.state = ServerSnapshot{...s.state, connected: true, busy: false, control_path: s.session_reference()}
		$if !windows { if !isnil(s.prompts) { s.prompts.close(); s.prompts = unsafe { nil } } }
		s.inspect() or { s.state = ServerSnapshot{...s.state, error: true, message: err.msg()} }
	} else if time.ticks() > s.deadline {
		s.close()
		s.state = ServerSnapshot{server_id: s.server.id, error: true, message: 'SSH 连接超时，请检查服务器和认证信息。'}
	}
}

fn validate_remote_project(command ServerCommand) ! {
	name := command.name
	if name.len < 1 || name.len > 64 || !name.bytes().all(it.is_alnum() || it in [u8(`-`), `_`]) || !name[0].is_alnum() { return error('实例名称使用 1–64 位字母、数字、短横线或下划线，并以字母或数字开头。') }
	if command.web_port < 1024 || command.web_port > 65535 || command.admin_port < 1024 || command.admin_port > 65535 || command.web_port == command.admin_port { return error('监听与 Admin 使用不同的 1024–65535 端口。') }
	if !project_templates().any(it.id == command.template) { return error('请选择 vjsx 模板。') }
}

fn (mut s ServerSession) create(command ServerCommand) ! {
	validate_remote_project(command)!
	s.discover_projects()!
	runtime := select_remote_runtime(s.state.runtimes, command.runtime_id)!

	template := project_templates().filter(it.id == command.template)[0]
	mut profiles := load_remote_profiles()!
	previous := profiles.filter(it.server_id == s.server.id && it.name == command.name)
	if previous.len > 0 && previous[0].runtime_id != '' && previous[0].runtime_id != runtime.id { return error('该实例已绑定其他运行包，请选择原版本重试。') }
	if previous.len > 0 && previous[0].admin_port != command.admin_port { return error('该实例已创建；请使用原 Admin 端口重试，或换一个实例名称。') }
	token := if previous.len > 0 { previous[0].token } else { rand.bytes(32)!.hex() }
	config := template.config_text.replace('entry = "main.mts"', 'entry = "main.mjs"')
		.replace('runtime_profile = "node"', 'runtime_profile = "script"')
		.replace('port = ${template.web_port}', 'port = ${command.web_port}')
		.replace('port = ${template.admin_port}', 'port = ${command.admin_port}')
		.replace('local-development-only', token)
	profile := if previous.len > 0 { previous[0] } else { RemoteProfile{id: new_remote_id()!, server_id: s.server.id, name: command.name, ssh_host: s.server.ssh_host, ssh_user: s.server.ssh_user,
		ssh_port: s.server.ssh_port, auth_method: s.server.auth_method, identity_file: s.server.identity_file, admin_port: command.admin_port, token: token, config_path: s.state.root + '/instances/' + command.name + '/vhttpd.toml', runtime_id: runtime.id, runtime_path: runtime.path + '/vhttpd'}
	}
	// Persist before reporting success, so reconnect does not require copying a token.
	if previous.len == 0 { profiles << profile; save_remote_profiles(profiles)! }
	script := 'set -eu\numask 077\nruntime_id=' + shell_quote(runtime.id) + '\ninstance_id=' + shell_quote(profile.id) + '\nreuse=' + if previous.len > 0 { '1' } else { '0' } + '\nname=' + shell_quote(command.name) + '\nconfig=' + shell_quote(base64.encode_str(config)) + '\nsource=' + shell_quote(base64.encode_str(template.source_text)) + '\n' + $embed_file('remote_scripts/create.sh').to_string()
	s.shell(script, 20000)!
	s.discover_projects()!
	s.state = ServerSnapshot{...s.state, created: profile, message: '实例已创建并启动，正在连接 Admin UI 并检查整项目生效状态。'}
}

fn shell_quote(value string) string { return "'" + value.replace("'", "'\"'\"'") + "'" }

fn (mut s ServerSession) install(archive_path string) ! {
	s.install_release(archive_path, '')!
}

fn (mut s ServerSession) install_release(archive_path string, tag string) ! {
	if s.state.platform == '' { return error('请先连接并识别服务器。') }
	temp := '/tmp/vh-package-' + new_remote_id()!
	os.mkdir(temp, mode: 0o700)!
	defer { os.rmdir_all(temp) or {} }
	mut archive := archive_path
	mut release_tag := if tag != '' { normalize_runtime_tag(tag)! } else { '' }
	if archive == '' {
		choice := resolve_runtime_download(s.state.platform, tag, s.job)!
		archive = download_runtime_files(choice, temp, s.job)!
		release_tag = choice.tag
	}
	validate_remote_archive(archive, s.state.platform, s.job)!
	// scp uses only the authenticated master; it cannot prompt or fall back.
	remote_name := 'vhttpd-upload-' + new_remote_id()! + '.tar.gz'
	mut args := ['-O', '-o', 'ControlPath=' + s.directory + '/control', '-o', 'ControlMaster=no', '-o', 'BatchMode=yes', '-o', 'ProxyCommand=false']
	$if windows { args = windows_auth_options(s.server); args.insert(0, '-O') }
 if s.server.ssh_port > 0 { args << ['-P', s.server.ssh_port.str()] }
	destination := if s.server.ssh_user == '' { s.server.ssh_host } else { s.server.ssh_user + '@' + s.server.ssh_host }
	args << [os.real_path(archive), destination + ':' + remote_name]
	$if windows { s.windows_scp(args, 120000)! } $else { s.job.command(s.scp_executable, args, 120000)! }
	expected := checksum_for(os.read_file(archive + '.sha256')!, os.file_name(archive))!
	s.shell('set -eu\numask 077\nrelease_tag=' + shell_quote(release_tag) + '\nupload=' + shell_quote(remote_name) + '\nexpected=' + shell_quote(expected) + '\nplatform=' + shell_quote(s.state.platform) + '\n' + $embed_file('remote_scripts/install.sh').to_string(), 30000)!
	s.inspect()!
}

fn validate_remote_archive(path string, platform string, job RuntimeJob) ! {
	name := 'vhttpd-${platform}'
	if os.file_name(path) != name + '.tar.gz' || !os.is_file(path) || os.file_size(path) > 268435456 || os.file_size(path + '.sha256') > 1048576 { return error('请选择对应架构的官方 .tar.gz 包，并将同名 .sha256 文件放在旁边。') }
	expected := checksum_for(os.read_file(path + '.sha256')!, os.file_name(path))!
	actual := sha256.sum(os.read_bytes(path)!).hex()
	if actual != expected { return error('SHA256 不匹配，未上传或安装，请重新下载运行包。') }
	listing := job.command('/usr/bin/tar', ['-tzf', path], 15000)!
	for item in listing.split_into_lines() {
		if item != name && !item.starts_with(name + '/') { return error('运行包目录无效。') }
		if item.split('/').any(it in ['..', '.']) || item.contains('\\') { return error('运行包包含不安全路径。') }
	}
	if !listing.split_into_lines().contains(name + '/vhttpd') || !listing.contains(name + '/admin/ui/index.html') { return error('运行包缺少 vhttpd 或 Admin UI，请使用新版 CI 完整包。') }
	types := job.command('/usr/bin/tar', ['-tvzf', path], 15000)!
	if types.split_into_lines().any(it.len > 0 && it[0] !in [u8(`-`), `d`]) { return error('运行包包含链接或特殊文件，无法安装。') }
}

fn server_supervise(w ServerWorker) {
	mut s := &ServerSession{job: w.job}
	mut sequence := u64(0)
	for {
		select {
			command := <-w.commands {
				sequence = command.sequence
				s.state = ServerSnapshot{...s.state, sequence: command.sequence}
				if command.action == .start { s.state = ServerSnapshot{ ...s.state, created: RemoteProfile{} } }
				if command.action in [.install, .create, .start, .upgrade, .inspect, .prepare_deploy, .deploy, .discard_deploy] {
					s.state = ServerSnapshot{...s.state, busy: true}
					select { w.snapshots <- s.state {} else {} }
				}
				mut failure := ''
				match command.action {
					.connect { s.connect(command.server, command.password) or { s.close(); failure = err.msg() } }
					.trust {
						if !isnil(s.prompts) && command.host_key_id != '' && command.host_key_id == s.state.host_key.id && !s.state.host_key_changed {
							s.prompts.decisions <- command.host_key_id
							s.state = ServerSnapshot{...s.state, host_key: RemoteHostKey{}, message: '指纹已确认，正在认证…'}
							s.deadline = time.ticks() + 15000
						}
					}
					.disconnect { s.close() }
					.inspect { s.inspect() or { failure = err.msg() } }
					.prepare_deploy { s.prepare_application(command) or { failure=err.msg() } }
					.deploy { s.deploy_application(command) or { failure=err.msg() } }
					.discard_deploy { s.discard_deployment() or { failure=err.msg() } }
					.upgrade { s.upgrade(command) or { failure = err.msg() } }
					.install { s.install_release(command.archive, command.release_tag) or { failure = err.msg() } }
					.create { s.create(command) or { failure = err.msg() } }
					.start { s.start_project(command) or { failure = err.msg() } }
					.shutdown { s.close(); w.done <- true; return }
				}
				if failure != '' { s.state = ServerSnapshot{...s.state, server_id: s.server.id, error: true, busy: false, message: failure} }
				s.state = ServerSnapshot{...s.state, sequence: sequence, busy: if command.action in [.connect, .trust] { s.state.busy } else { false }}
			}
			else {}
		}
		s.tick()
		s.state = ServerSnapshot{...s.state, sequence: sequence}
		select { w.snapshots <- s.state {} else {} }
		time.sleep(80 * time.millisecond)
	}
}

fn parse_remote_runtimes(records []string, root string) ![]RemoteRuntime {
	mut runtimes := []RemoteRuntime{}
	for line in records {
		parts := line.split(':')
		if parts.len != 4 || !remote_runtime_id_valid(parts[1]) || runtimes.any(it.id == parts[1]) || runtimes.len >= 65 { return error('远端运行包目录无效，请检查后刷新。') }
		version := runtime_version_text(base64.decode_str(parts[2]))!
		tag := base64.decode_str(parts[3])
		if tag != '' { normalize_runtime_tag(tag)! }
		runtimes << RemoteRuntime{id: parts[1], version: version, release_tag: tag, path: root + if parts[1] == 'legacy' { '/runtime' } else { '/runtimes/' + parts[1] }}
	}
	return runtimes
}

fn select_remote_runtime(runtimes []RemoteRuntime, selected string) !RemoteRuntime {
	if selected == '' && runtimes.len == 1 { return runtimes[0] }
	for runtime in runtimes { if runtime.id == selected { return runtime } }
	return error('请选择服务器上已安装的运行包版本。')
}

fn (s &ServerSession) session_reference() string {
 $if windows { return s.windows_ticket } $else { return s.directory + '/control' }
}
fn (s &ServerSession) session_available() bool {
 $if windows { return windows_session_alive(s.windows_ticket) } $else { return os.exists(s.directory + '/control') }
}
fn (s &ServerSession) transport_ready() bool {
 $if windows { return s.windows_ready() } $else { return os.exists(s.directory + '/control') }
}
fn ssh_control_exists(reference string) bool {
 $if windows { return windows_session_alive(reference) } $else { return os.exists(reference) }
}
