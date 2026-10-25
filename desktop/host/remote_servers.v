module host

import crypto.rand
import crypto.sha256
import encoding.base64
import json2 as json
import os
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

pub enum ServerAction { connect trust disconnect inspect install create shutdown }
pub struct ServerCommand {
pub:
	sequence u64
	action ServerAction
	server RemoteServer
	password string
	host_key_id string
	archive string
	name string
	template string = 'vjsx-http'
	web_port int = 19881
	admin_port int = 2018
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
	control_path string
	// Creation remains visible until the UI acknowledges it with inspect.
	created RemoteProfile
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
	ssh_executable string = '/usr/bin/ssh'
	scp_executable string = '/usr/bin/scp'
	server RemoteServer
	process &os.Process = unsafe { nil }
	prompts &RemoteAskpass = unsafe { nil }
	directory string
	diagnostics string
	deadline i64
	state ServerSnapshot
	job RuntimeJob
}

fn (mut s ServerSession) close() {
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
	s.directory = '/tmp/vh-host-' + new_remote_id()!
	os.mkdir(s.directory, mode: 0o700)!
	mut args := ['-N', '-T', '-M', '-S', s.directory + '/control', '-o', 'ControlPersist=no',
		'-o', 'StrictHostKeyChecking=ask', '-o', 'FingerprintHash=sha256', '-o', 'UpdateHostKeys=no',
		'-o', 'ForwardAgent=no', '-o', 'ForkAfterAuthentication=no', '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2']
	if server.auth_method == 'password' {
		args << ['-o', 'BatchMode=no', '-o', 'PasswordAuthentication=yes', '-o', 'PreferredAuthentications=password', '-o', 'PubkeyAuthentication=no',
			'-o', 'KbdInteractiveAuthentication=no', '-o', 'NumberOfPasswordPrompts=1']
	} else {
		args << ['-o', 'BatchMode=no', '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no']
		if server.identity_file != '' { args << ['-i', server.identity_file] }
	}
	s.prompts = new_remote_prompts(password, server.auth_method == 'password')!
	args << s.destination_args()
	s.process = os.new_process(s.ssh_executable)
	s.process.set_args(args)
	s.process.set_redirect_stdio()
	s.process.set_environment(s.prompts.environment())
	s.process.run()
	s.diagnostics = ''
	s.deadline = time.ticks() + 15000
	s.state = ServerSnapshot{server: server, server_id: server.id, busy: true, message: '正在连接服务器；不需要 Admin Token。'}
}

// Mux commands cannot fall back to another SSH authentication when disconnected.
fn (s &ServerSession) mux_args() []string {
	return ['-T', '-S', s.directory + '/control', '-o', 'ControlMaster=no', '-o', 'BatchMode=yes', '-o', 'ProxyCommand=false']
}

fn (s &ServerSession) shell(script string, timeout i64) !string {
	if !s.state.connected || !os.exists(s.directory + '/control') { return error('请先连接服务器。') }
	// Bounded scripts fit in the SSH stdin pipe. Secrets never become files or arguments.
	if script.len > 16000 { return error('部署配置过大。') }
	mut child := os.new_process(s.ssh_executable)
	mut args := s.mux_args()
	args << s.destination_args()
	args << '/bin/sh -s'
	child.set_args(args)
	child.set_redirect_stdio_merged()
	child.use_pgroup = true
	child.run()
	defer { child.close() }
	child.stdin_write(script + '\nexit\n')
	os.fd_close(child.stdio_fd[0])
	child.stdio_fd[0] = -1
	until := time.ticks() + timeout
	mut output := ''
	for {
		for _ in 0 .. 8 {
			if !child.is_pending(.stdout) { break }
			output += child.stdout_read()
		}
		if output.len > 65536 || time.ticks() > until {
			child.signal_pgkill(); child.signal_kill(); child.wait()
			return error('服务器操作超时或输出过多；请刷新运行环境确认结果。')
		}
		select { _ := <-s.job.cancel { child.signal_pgkill(); child.signal_kill(); child.wait(); return error('操作已取消，请刷新服务器状态。') } else {} }
		if !child.is_alive() { break }
		time.sleep(20 * time.millisecond)
	}
	child.wait()
	for child.is_pending(.stdout) { part := child.stdout_read(); if part == '' { break }; output += part }
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
	mut version := ''
	for line in output.split_into_lines() {
		if line.starts_with('VHTTPD_PLATFORM:') { platform = line.all_after(':') }
		if line.starts_with('VHTTPD_ROOT:') { root = base64.decode_str(line.all_after(':')) }
		if line.starts_with('VHTTPD_VERSION:') { version = runtime_version_text(line.all_after(':'))! }
	}
	if platform !in ['linux-amd64', 'linux-arm64'] || !root.starts_with('/') || root.contains('\n') { return error('当前只支持 Linux amd64 / arm64 服务器。') }
	s.state = ServerSnapshot{...s.state, platform: platform, root: root, version: version, error: false, created: RemoteProfile{},
		message: if version == '' { '服务器已连接，尚未安装运行包。先安装，再创建实例。' } else { '运行环境已就绪。创建实例后可直接打开 Admin UI。' }}
}

fn (mut s ServerSession) tick() {
	if isnil(s.process) { return }
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
	if s.state.connected { return }
	if s.state.host_key.id != '' { return }
	if os.exists(s.directory + '/control') {
		s.state = ServerSnapshot{...s.state, connected: true, busy: false, control_path: s.directory + '/control'}
		if !isnil(s.prompts) { s.prompts.close(); s.prompts = unsafe { nil } }
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
	if s.state.version == '' { return error('请先安装远端运行包。') }
	template := project_templates().filter(it.id == command.template)[0]
	mut profiles := load_remote_profiles()!
	previous := profiles.filter(it.server_id == s.server.id && it.name == command.name)
	if previous.len > 0 && previous[0].admin_port != command.admin_port { return error('该实例已创建；请使用原 Admin 端口重试，或换一个实例名称。') }
	token := if previous.len > 0 { previous[0].token } else { rand.bytes(32)!.hex() }
	config := template.config_text.replace('entry = "main.mts"', 'entry = "main.mjs"')
		.replace('runtime_profile = "node"', 'runtime_profile = "script"')
		.replace('port = ${template.web_port}', 'port = ${command.web_port}')
		.replace('port = ${template.admin_port}', 'port = ${command.admin_port}')
		.replace('local-development-only', token)
	profile := if previous.len > 0 { previous[0] } else { RemoteProfile{id: new_remote_id()!, server_id: s.server.id, name: command.name, ssh_host: s.server.ssh_host, ssh_user: s.server.ssh_user,
		ssh_port: s.server.ssh_port, auth_method: s.server.auth_method, identity_file: s.server.identity_file, admin_port: command.admin_port, token: token}
	}
	// Persist before reporting success, so reconnect does not require copying a token.
	if previous.len == 0 { profiles << profile; save_remote_profiles(profiles)! }
	script := 'set -eu\numask 077\ninstance_id=' + shell_quote(profile.id) + '\nreuse=' + if previous.len > 0 { '1' } else { '0' } + '\nname=' + shell_quote(command.name) + '\nconfig=' + shell_quote(base64.encode_str(config)) + '\nsource=' + shell_quote(base64.encode_str(template.source_text)) + '\n' + $embed_file('remote_scripts/create.sh').to_string()
	s.shell(script, 20000)!
	s.state = ServerSnapshot{...s.state, created: profile, message: '实例已创建并启动，正在连接 Admin UI 并检查整项目生效状态。'}
}

fn shell_quote(value string) string { return "'" + value.replace("'", "'\"'\"'") + "'" }

fn (mut s ServerSession) install(archive_path string) ! {
	if s.state.platform == '' { return error('请先连接并识别服务器。') }
	if s.state.version != '' { return error('运行包已安装；第一版暂不提供远端升级。') }
	temp := '/tmp/vh-package-' + new_remote_id()!
	os.mkdir(temp, mode: 0o700)!
	defer { os.rmdir_all(temp) or {} }
	mut archive := archive_path
	if archive == '' {
		metadata := temp + '/release.json'
		s.job.fetch('https://api.github.com/repos/guweigang/vhttpd/releases/latest', metadata, 2097152) or { return error('暂未找到可下载的正式 Release。可以选择 GitHub CI 构建的 Linux 包及同名 .sha256 校验文件。') }
		release := json.decode[RuntimeRelease](os.read_file(metadata)!)!
		name := 'vhttpd-${s.state.platform}.tar.gz'
		packages := release.assets.filter(it.name == name)
		checks := release.assets.filter(it.name == name + '.sha256')
		if release.draft || release.prerelease || packages.len != 1 || checks.len != 1 { return error('正式 Release 尚未提供该 Linux 架构的运行包和校验文件。请选择官方 CI 下载包。') }
		if !official_asset_url(packages[0].browser_download_url) || !official_asset_url(checks[0].browser_download_url) { return error('下载地址不是官方 Release。') }
		archive = temp + '/' + name
		s.job.fetch(packages[0].browser_download_url, archive, 268435456)!
		s.job.fetch(checks[0].browser_download_url, archive + '.sha256', 1048576)!
	}
	validate_remote_archive(archive, s.state.platform, s.job)!
	// scp uses only the authenticated master; it cannot prompt or fall back.
	remote_name := 'vhttpd-upload-' + new_remote_id()! + '.tar.gz'
	mut args := ['-O', '-o', 'ControlPath=' + s.directory + '/control', '-o', 'ControlMaster=no', '-o', 'BatchMode=yes', '-o', 'ProxyCommand=false']
	if s.server.ssh_port > 0 { args << ['-P', s.server.ssh_port.str()] }
	destination := if s.server.ssh_user == '' { s.server.ssh_host } else { s.server.ssh_user + '@' + s.server.ssh_host }
	args << [os.real_path(archive), destination + ':' + remote_name]
	s.job.command(s.scp_executable, args, 120000)!
	expected := checksum_for(os.read_file(archive + '.sha256')!, os.file_name(archive))!
	s.shell('set -eu\numask 077\nupload=' + shell_quote(remote_name) + '\nexpected=' + shell_quote(expected) + '\nplatform=' + shell_quote(s.state.platform) + '\n' + $embed_file('remote_scripts/install.sh').to_string(), 30000)!
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
				if command.action in [.install, .create, .inspect] {
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
					.install { s.install(command.archive) or { failure = err.msg() } }
					.create { s.create(command) or { failure = err.msg() } }
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
