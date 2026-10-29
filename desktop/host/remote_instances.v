module host

import crypto.rand
import browser_auth
import json2 as json
import net
import net.http
import os
import time

// Transport and lifecycle remain separate: systemd/container adapters can replace
// manual restart without changing the authenticated Admin connection.
pub struct RemoteProfile {
pub:
	id            string
	server_id     string
	runtime_id    string
	runtime_path  string
	config_path   string
	name          string
	ssh_host      string
	ssh_user      string
	ssh_port      int
	identity_file string
	auth_method   string = 'key'
	admin_port    int = 2018
	token         string
	restart_kind  string = 'manual'
}

pub fn (p RemoteProfile) validate() ! {
	if p.auth_method !in ['key', 'password'] { return error('请选择密码或密钥认证。') }
	if p.id.len != 24 || !p.id.bytes().all(it.is_hex_digit()) {
		return error('连接编号无效，请新建连接。')
	}
	if p.name.trim_space() == '' || p.name.len > 120 { return error('请填写实例名称。') }
	if p.ssh_host == '' || p.ssh_host.len > 253 || p.ssh_host.starts_with('-') || !p.ssh_host.bytes().all(it.is_alnum() || it in [
		u8(`.`),
		`-`,
		`_`,
		`:`,
	]) {
		return error('SSH 主机请填写主机名、IP 或已有 SSH Host 别名。')
	}
	if p.ssh_user != '' && (p.ssh_user.starts_with('-') || !p.ssh_user.bytes().all(it.is_alnum() || it in [
		u8(`-`),
		`_`,
		`.`,
	])) {
		return error('SSH 用户名无效。')
	}
	if p.ssh_port < 0 || p.ssh_port > 65535 || p.admin_port < 1 || p.admin_port > 65535 {
		return error('端口应为 1–65535。')
	}
	if p.token == '' || p.token.len > 4096 || p.token.contains('\n') || p.token.contains('\r') {
		return error('请填写远端 Admin Token。')
	}
	if p.restart_kind != 'manual' {
		return error('当前仅支持手工启动实例；systemd、Docker/Compose 适配尚未提供。')
	}
}

pub fn new_remote_id() !string { return rand.bytes(12)!.hex() }

fn remote_profiles_path() string {
	return os.join_path(workbench_data_dir(), 'remote-instances.json')
}

pub fn load_remote_profiles() ![]RemoteProfile {
	path := remote_profiles_path()
	if !os.exists(path) { return []RemoteProfile{} }
	if os.is_link(path) || os.file_size(path) > 1048576 {
		return error('远端连接文件无效。')
	}
	os.chmod(path, 0o600)!
	profiles := json.decode[[]RemoteProfile](os.read_file(path)!)!
	if profiles.len > 128 { return error('远端连接记录过多。') }
	mut ids := map[string]bool{}
	for p in profiles {
		p.validate()!
		if p.id in ids { return error('远端连接编号重复。') }
		ids[p.id] = true
	}
	return profiles
}

pub fn save_remote_profiles(profiles []RemoteProfile) ! {
	if profiles.len > 128 { return error('最多保存 128 个远端连接。') }
	mut ids := map[string]bool{}
	for p in profiles {
		p.validate()!
		if p.id in ids { return error('远端连接编号重复。') }
		ids[p.id] = true
	}
	os.mkdir_all(workbench_data_dir())!
	os.chmod(workbench_data_dir(), 0o700)!
	path := remote_profiles_path()
	if os.is_link(path) { return error('远端连接文件不能为符号链接。') }
	temp := path + '.' + new_remote_id()!
	defer { os.rm(temp) or {} }
	write_project_contents(create_project_file(temp)!, json.encode(profiles))!
	os.mv(temp, path)!
}

pub struct RemoteOperation {
pub:
	id                string
	state             string
	expected_boot     string
	expected_revision string
	pid               int
	log_path          string
	error             string
}

pub struct RemoteInstance {
pub:
	instance_id        string
	boot_id            string
	version            string
	platform           string
	config_path        string
	effective_revision string
	disk_revision      string
	ready              bool
	manual_restart     bool
	operation          RemoteOperation
	error              string
}

// A failed operation must outrank a matching configuration manifest: loading
// every include is not the same as successfully starting the business runtime.
pub fn (instance RemoteInstance) startup_failed() bool {
	return instance.operation.state == 'failed' && (!instance.ready || instance.operation.error == 'executor_warmup_failed')
}

fn remote_restart_failure_is_current(instance RemoteInstance, restarting bool, expected_boot string) bool {
	// During a retry, a response from the previous failed boot is not the result
	// of the new restart operation. Keep reconciling until a new boot responds.
	return instance.startup_failed() && (!restarting || instance.boot_id != expected_boot)
}

fn remote_failed_startup_snapshot(profile_id string, instance RemoteInstance, status ConfigStatus) RemoteSnapshot {
	reason := if instance.operation.error == 'executor_warmup_failed' { '执行器初始化失败' } else { '业务进程启动失败' }
	return RemoteSnapshot{profile_id: profile_id, connected: true, instance: instance,
		config_status: ConfigStatus{...status, state: .pending, pending: true, message: '业务启动失败，尚未确认整个项目生效。'},
		message: '远端重启失败：' + reason + '。请打开 Admin UI 修复配置、重新校验并发布，再点击“修复后重试重启”。不会自动重复重启。'}
}

pub struct RemoteSnapshot {
pub:
	admin_url string
	sequence      u64
	profile_id    string
	connected     bool
	busy          bool
	restarting    bool
	message       string
	instance      RemoteInstance
	config_status ConfigStatus
	host_key      RemoteHostKey
	host_key_changed bool
}

pub enum RemoteAction {
	connect
	confirm_host_key
	disconnect
	open_admin
	restart
	check
	shutdown
}

pub struct RemoteCommand {
pub:
	// Owned session socket; never persisted with the instance.
	control_path string
	sequence u64
	action   RemoteAction
	profile  RemoteProfile
	// Ephemeral command payload, deliberately absent from persisted profiles.
	password string
	host_key_id string
}

pub struct RemoteWorker {
pub:
	commands  chan RemoteCommand  = chan RemoteCommand{cap: 8}
	snapshots chan RemoteSnapshot = chan RemoteSnapshot{cap: 1}
	done      chan bool           = chan bool{cap: 1}
}

pub fn new_remote_worker() RemoteWorker {
	worker := RemoteWorker{}
	spawn remote_supervise(worker)
	return worker
}

// A browser endpoint is bound to one exact profile for this Desktop session.
// Inactive endpoints return 410 rather than silently forwarding old tabs to
// another project. Reconnecting the same profile resets its browser login.
struct RemoteBrowserEndpoint {
	profile RemoteProfile
	server &http.Server
	proxy &RemoteProxy
}

@[heap]
struct RemoteManager {
mut:
	profile           RemoteProfile
	ssh_executable    string       = ssh_tool('ssh')
	ssh               &os.Process  = unsafe { nil }
	server            &http.Server = unsafe { nil }
	proxy             &RemoteProxy = unsafe { nil }
	snapshot          RemoteSnapshot
	deadline          i64
	next_probe        i64
	expected_boot     string
	expected_revision string
	handoffs          []BrowserHandoff
	askpass           &RemoteAskpass = unsafe { nil }
	ssh_diagnostics string
	control_path string
	mux_forward string
	browser_endpoints []RemoteBrowserEndpoint
}

fn (mut m RemoteManager) disconnect() {
	if m.control_path != '' && m.mux_forward != '' && os.exists(m.control_path) {
		mut args := ['-S', m.control_path, '-o', 'BatchMode=yes', '-o', 'ProxyCommand=false', '-O', 'cancel', '-L', m.mux_forward]
		if m.profile.ssh_port > 0 { args << ['-p', m.profile.ssh_port.str()] }
		if m.profile.ssh_user != '' { args << ['-l', m.profile.ssh_user] }
		args << m.profile.ssh_host
		RuntimeJob{}.command(m.ssh_executable, args, 3000) or {}
	}
	m.control_path = ''
	m.mux_forward = ''
	if !isnil(m.askpass) { m.askpass.close(); m.askpass = unsafe { nil } }
	if !isnil(m.proxy) {
		m.proxy.mu.@lock()
		m.proxy.active = false
		m.proxy.mu.unlock()
	}
	if !isnil(m.ssh) {
		m.ssh.signal_term()
		limit := time.ticks() + 1500
		for m.ssh.is_alive() && time.ticks() < limit { time.sleep(20 * time.millisecond) }
		if m.ssh.is_alive() { m.ssh.signal_kill() }
		m.ssh.wait()
		m.ssh.close()
	}
	m.ssh = unsafe { nil }
	m.ssh_diagnostics = ''
	for file in m.handoffs { os.rm(file.path) or {} }
	m.handoffs = []BrowserHandoff{}
	m.snapshot = RemoteSnapshot{ message: '连接已断开，远端 vhttpd 继续运行。' }
}

fn (mut m RemoteManager) connect(profile RemoteProfile) ! {
	m.connect_with_password(profile, '')!
}

fn (mut m RemoteManager) connect_with_password(profile RemoteProfile, password string) ! {
	m.connect_with_session(profile, password, '')!
}

fn (mut m RemoteManager) connect_with_session(profile RemoteProfile, password string, control_path string) ! {
	$if !macos && !linux {
		return error('当前 SSH 传输支持 macOS / Linux；Windows 适配尚未启用。')
	}
	profile.validate()!
	if profile.auth_method == 'password' && control_path == '' { validate_ssh_password(password)! }
	if profile.auth_method == 'key' && profile.identity_file != '' && !os.is_file(profile.identity_file) {
		return error('SSH 私钥文件不存在，请重新选择或使用 SSH 配置。')
	}
	m.disconnect()
	mut established := false
	defer { if !established { m.disconnect() } }
	m.profile = profile
	mut reserve := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := reserve.addr()!.port()!
	reserve.close()!
	mut args := ['-N', '-T', '-o', 'ControlMaster=no',
		'-o', 'StrictHostKeyChecking=ask', '-o', 'FingerprintHash=sha256', '-o', 'UpdateHostKeys=no', '-o', 'ExitOnForwardFailure=yes', '-o', 'ConnectTimeout=8',
		'-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2', '-o', 'ForwardAgent=no',
		'-L', '127.0.0.1:${port}:127.0.0.1:${profile.admin_port}']
	if profile.ssh_port > 0 { args << ['-p', profile.ssh_port.str()] }
	if profile.ssh_user != '' { args << ['-l', profile.ssh_user] }
	if control_path != '' {
		if !os.exists(control_path) { return error('服务器会话已断开，请重新连接服务器。') }
		args << ['-S', control_path, '-o', 'BatchMode=yes', '-o', 'ProxyCommand=false']
	} else if profile.auth_method == 'password' {
		args << ['-o', 'BatchMode=no', '-o', 'PreferredAuthentications=password',
			'-o', 'PasswordAuthentication=yes', '-o', 'PubkeyAuthentication=no',
			'-o', 'KbdInteractiveAuthentication=no', '-o', 'NumberOfPasswordPrompts=1']
	} else {
		args << ['-o', 'BatchMode=no', '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no']
		if profile.identity_file != '' { args << ['-i', profile.identity_file] }
	}
	if control_path == '' { m.askpass = new_remote_prompts(password, profile.auth_method == 'password')! }
	args << profile.ssh_host
	if control_path != '' {
		// A mux client with -N exits after creating forwards. Own the forward
		// explicitly; the server session owns and supervises the master process.
		mut forward_args := ['-S', control_path, '-o', 'BatchMode=yes', '-o', 'ProxyCommand=false', '-O', 'forward', '-L', '127.0.0.1:${port}:127.0.0.1:${profile.admin_port}']
		if profile.ssh_port > 0 { forward_args << ['-p', profile.ssh_port.str()] }
		if profile.ssh_user != '' { forward_args << ['-l', profile.ssh_user] }
		forward_args << profile.ssh_host
		RuntimeJob{}.command(m.ssh_executable, forward_args, 5000)!
		m.control_path = control_path
		m.mux_forward = '127.0.0.1:${port}:127.0.0.1:${profile.admin_port}'
	} else {
		args.insert(0, '-o')
		args.insert(1, 'ControlPath=none')
		mut ssh := os.new_process(m.ssh_executable)
		ssh.set_args(args)
		ssh.set_redirect_stdio()
		if !isnil(m.askpass) { ssh.set_environment(m.askpass.environment()) }
		ssh.run()
		m.ssh = ssh
	}
	mut existing_endpoint := false
	for endpoint in m.browser_endpoints {
		if endpoint.profile == profile { m.server = endpoint.server; m.proxy = endpoint.proxy; existing_endpoint = true; break }
	}
	if !existing_endpoint {
		mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
		origin := 'http://127.0.0.1:${listener.addr()!.port()!}'
		m.proxy = &RemoteProxy{ origin: origin, target: 'http://127.0.0.1:${port}', token: profile.token }
		m.server = &http.Server{ listener: listener, handler: m.proxy, show_startup_message: false, accept_timeout: 100 * time.millisecond, read_timeout: 20 * time.second, worker_num: 4 }
		m.browser_endpoints << RemoteBrowserEndpoint{profile: profile, server: m.server, proxy: m.proxy}
		spawn m.server.listen_and_serve()
	} else {
		m.proxy.mu.@lock()
		m.proxy.target = 'http://127.0.0.1:${port}'
		m.proxy.token = profile.token
		m.proxy.auth = &browser_auth.BrowserAuth{}
		m.proxy.active = true
		m.proxy.mu.unlock()
	}
	m.deadline = time.ticks() + 12000
	m.next_probe = 0
	m.snapshot = RemoteSnapshot{ profile_id: profile.id, busy: true, message: '正在建立 SSH 隧道并验证远端 Admin 连接…' }
	established = true
}

fn (mut m RemoteManager) confirm_host_key(id string) ! {
	if isnil(m.askpass) || id == '' || id != m.snapshot.host_key.id || m.snapshot.host_key_changed {
		return error('主机指纹确认已失效，请重新连接。')
	}
	m.askpass.decisions <- id
	m.snapshot = RemoteSnapshot{ ...m.snapshot, host_key: RemoteHostKey{}, message: '已确认主机指纹，正在验证远端连接…' }
	m.deadline = time.ticks() + 12000
	m.next_probe = 0
}

fn (m &RemoteManager) request(method http.Method, path string, data string) !http.Response {
	if isnil(m.proxy) { return error('请先连接远端实例。') }
	mut request := http.Request{ method: method, url: m.proxy.target + path, data: if method == .post && data == '' { '{}' } else { data }, read_timeout: 2 * time.second, write_timeout: 2 * time.second, max_retries: 1, allow_redirect: false, disable_connection_reuse: true }
	request.add_custom_header('x-vhttpd-admin-token', m.profile.token)!
	if method == .post { request.header.set(.content_type, 'application/json') }
	return request.do()!
}

fn (mut m RemoteManager) restart() ! {
	if !m.snapshot.connected || m.snapshot.restarting {
		return error('请先连接并等待当前操作结束。')
	}
	instance := m.snapshot.instance
	if !instance.manual_restart {
		return error('远端未启用手工重启。请由实例所有者使用 --manual-restart 启动；现有启动参数和环境将被保留。')
	}
	if instance.disk_revision == '' {
		return error('远端尚未就绪或项目校验失败，请先在 Admin UI 修复配置。')
	}
	id := new_remote_id()!
	// The same operation ID is used for outcome reconciliation; never blind retry.
	m.expected_boot = instance.boot_id
	m.expected_revision = instance.disk_revision
	response := m.request(.post, '/admin/workbench/restart', json.encode({
		'operation_id':      id
		'expected_boot':     instance.boot_id
		'expected_revision': instance.disk_revision
	})) or {
		m.snapshot = RemoteSnapshot{ ...m.snapshot, restarting: true, busy: true, message: '重启请求结果待确认，正在查询实例；不会重复发送。' }
		m.deadline = time.ticks() + 90000
		return
	}
	if response.status_code != 202 {
		return error('远端拒绝重启：配置可能已变化或校验失败。请检查整个项目后重试。')
	}
	m.snapshot = RemoteSnapshot{ ...m.snapshot, restarting: true, busy: true, message: '正在远端重启，等待新实例和整个项目配置生效…' }
	m.deadline = time.ticks() + 90000
	m.next_probe = 0
}

fn (mut m RemoteManager) browser_login() !string {
	if !m.snapshot.connected || isnil(m.proxy) { return error('请先连接远端实例。') }
	ticket := m.proxy.auth.issue_ticket(time.now().unix())!
	path := os.join_path(os.temp_dir(), 'vhttpd-remote-login-' + new_remote_id()! + '.html')
	write_project_contents(create_project_file(path)!, login_document(m.proxy.origin + '/admin/auth/exchange', ticket))!
	m.handoffs << BrowserHandoff{ path: path, expires: time.ticks() + 35000 }
	return path
}

fn (mut m RemoteManager) tick() {
	for file in m.handoffs { if file.expires <= time.ticks() { os.rm(file.path) or {} } }
	m.handoffs = m.handoffs.filter(it.expires > time.ticks())
	if isnil(m.ssh) && m.control_path == '' { return }
	for _ in 0 .. 8 {
		if isnil(m.ssh) { break }
		part := m.ssh.stderr_read()
		if part == '' { break }
		combined := m.ssh_diagnostics + part
		m.ssh_diagnostics = if combined.len > 16384 { combined[combined.len - 16384..] } else { combined }
	}
	if !isnil(m.askpass) {
		select {
			challenge := <-m.askpass.challenges {
				m.snapshot = RemoteSnapshot{ ...m.snapshot, host_key: challenge, busy: true, message: '首次连接此 SSH 主机。请核对主机指纹，确认后才会继续认证。' }
			}
			else {}
		}
	}
	if m.snapshot.host_key.id != '' && !isnil(m.ssh) && m.ssh.is_alive() { return }
	if time.ticks() < m.next_probe { return }
	m.next_probe = time.ticks() + 1500
	if (m.control_path != '' && !os.exists(m.control_path)) || (m.control_path == '' && !m.ssh.is_alive()) {
		if !isnil(m.askpass) { m.askpass.close(); m.askpass = unsafe { nil } }
		if m.ssh_diagnostics.contains('REMOTE HOST IDENTIFICATION HAS CHANGED') || m.ssh_diagnostics.contains('REVOKED HOST KEY') || m.ssh_diagnostics.contains('POSSIBLE DNS SPOOFING DETECTED') {
			mut fingerprint := ''
			for word in m.ssh_diagnostics.fields() { if word.starts_with('SHA256:') { fingerprint = word.trim_right('.'); break } }
			m.snapshot = RemoteSnapshot{profile_id: m.profile.id, host_key_changed: true, host_key: RemoteHostKey{fingerprint: fingerprint}, message: 'SSH 主机指纹与已保存的记录不一致，连接已阻止。请通过可信渠道核对服务器是否重装或更换密钥；工作台不会自动覆盖已信任记录。'}
			return
		}
		m.snapshot = RemoteSnapshot{ ...m.snapshot, host_key: RemoteHostKey{}, connected: false, busy: false, restarting: false, message: if m.snapshot.host_key.id != '' { '主机指纹确认已取消或超时，请重新连接；未继续认证。' } else if m.profile.auth_method == 'password' { 'SSH 密码认证失败或连接已断开。请检查主机、用户和密码（重新输入后连接），确认服务器允许密码登录，并先在终端确认主机指纹。远端进程未被停止。' } else { 'SSH 连接失败或已断开。请确认 Host、用户、密钥及 known_hosts；先在终端执行 ssh 验证，再重新连接。远端进程未被停止。' } }
		return
	}
	response := m.request(.get, '/admin/workbench/instance', '') or { http.Response{} }
	if response.status_code != 200 {
		if response.status_code in [401, 403, 404] || time.ticks() > m.deadline {
			m.snapshot = RemoteSnapshot{
				...m.snapshot
				connected:  false
				busy:       false
				restarting: false
				message:    if response.status_code in [
					401,
					403,
				] {
					'SSH 已连接，Admin 认证失败。请检查远端 Token。'
				} else if response.status_code == 404 {
					'远端 vhttpd 缺少工作台管理 API，请使用支持此功能的版本。'
				} else {
					'无法确认远端运行状态。请检查管理端口或远端日志，再连接检查；不会自动重复重启。'
				}
			}
		}
		return
	}
	instance := json.decode[RemoteInstance](response.body) or {
		m.snapshot = RemoteSnapshot{ ...m.snapshot, connected: false, busy: false, restarting: false, message: '远端工作台状态无效，请检查管理端口和 vhttpd 版本。' }
		return
	}
	if !isnil(m.askpass) { m.askpass.close(); m.askpass = unsafe { nil } }
	if instance.instance_id == '' || instance.boot_id == '' {
		m.snapshot = RemoteSnapshot{ ...m.snapshot, connected: false, busy: false, restarting: false, message: '远端未提供项目配置来源，请使用 --config、VHTTPD_CONFIG 或 TOML 位置参数启动。' }
		return
	}
	mut status := check_config_status(m.proxy.target + '/admin/ui/', m.profile.token, instance.config_path)
	if !instance.ready && status.state == .effective {
		status = ConfigStatus{...status, state: .pending, pending: true, message: '业务尚未就绪，尚未确认整个项目生效。'}
	}
	if remote_restart_failure_is_current(instance, m.snapshot.restarting, m.expected_boot) {
		m.snapshot = remote_failed_startup_snapshot(m.profile.id, instance, status)
		return
	}
	if m.snapshot.restarting {
		if instance.boot_id != m.expected_boot && instance.ready && instance.effective_revision == m.expected_revision && instance.disk_revision == m.expected_revision && status.state == .effective {
			m.snapshot = RemoteSnapshot{ profile_id: m.profile.id, connected: true, instance: instance, config_status: status, message: '远端已重启，整个项目配置已生效。' }
		} else if time.ticks() > m.deadline {
			m.snapshot = RemoteSnapshot{ profile_id: m.profile.id, connected: true, instance: instance, config_status: status, message: '重启后尚未确认目标配置生效。请检查远端运行日志和配置；不会自动重复重启。' }
		} else {
			m.snapshot = RemoteSnapshot{ ...m.snapshot, instance: instance }
		}
		return
	}
	m.snapshot = RemoteSnapshot{
		profile_id:    m.profile.id
		connected:     true
		instance:      instance
		config_status: status
		message:       if !instance.ready {
			'管理连接正常，业务启动尚未就绪，请检查远端日志。'
		} else if instance.disk_revision == '' || status.state == .unavailable {
			'项目配置读取或校验失败，请在 Admin UI 检查配置来源。'
		} else if instance.disk_revision != instance.effective_revision || status.state == .pending {
			'配置已发布，待远端重启后生效。'
		} else {
			'连接正常，整个项目配置已生效。'
		}
	}
}

fn remote_supervise(worker RemoteWorker) {
	mut manager := &RemoteManager{}
	mut sequence := u64(0)
	for {
		select {
			command := <-worker.commands {
				sequence = command.sequence
				match command.action {
					.connect {
						manager.connect_with_session(command.profile, command.password, command.control_path) or {
							manager.disconnect()
							manager.snapshot = RemoteSnapshot{ profile_id: command.profile.id, message: err.msg() }
						}
					}
					.confirm_host_key {
						manager.confirm_host_key(command.host_key_id) or { manager.snapshot = RemoteSnapshot{ ...manager.snapshot, message: err.msg() } }
					}
					.disconnect { manager.disconnect() }
					.open_admin {
						path := manager.browser_login() or {
							manager.snapshot = RemoteSnapshot{ ...manager.snapshot, message: err.msg() }
							continue
						}
						open_local(path) or { manager.snapshot = RemoteSnapshot{ ...manager.snapshot, message: '浏览器打开失败，请重新点击。' } }
					}
					.restart {
						manager.restart() or { manager.snapshot = RemoteSnapshot{ ...manager.snapshot, message: err.msg() } }
					}
					.check { manager.next_probe = 0 }
					.shutdown {
						manager.disconnect()
						for endpoint in manager.browser_endpoints { mut server := endpoint.server; server.stop() }
						worker.done <- true
						return
					}
				}
			}
			else {
			}
		}
		manager.tick()
		select {
			worker.snapshots <- RemoteSnapshot{ ...manager.snapshot, sequence: sequence, admin_url: if manager.snapshot.connected && !isnil(manager.proxy) { manager.proxy.origin + '/admin/ui/' } else { '' } } {
			}
			else {
			}
		}
		time.sleep(80 * time.millisecond)
	}
}
