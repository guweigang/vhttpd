module host

import net
import net.http
import os
import crypto.rand as crypto_rand
import time

pub enum Phase {
	stopped
	starting
	running
	stopping
	failed
}

pub struct Snapshot {
pub:
	recovery_history []RecoveryVersionView
	history_comparison HistoryComparison
	recovery_saved bool
	rollback_preview RollbackPreview
	config_status ConfigStatus
	sequence    u64
	phase       Phase
	pid         int
	project     string
	admin_url   string
	app_url     string
	entry       string
	executor    string
	log_filter string
	log_focus_serial u64
	logs        string
	message     string
	can_force   bool
	ready_event bool
	// Runtime credential is memory-only; browser login uses a separate one-time ticket.
	token string
}

@[heap]
pub struct Manager {
mut:
	recovery_history []RecoveryVersion
	recovery_persisted_ids []string
	recovery_disk_revision string
	recovery_id string
	history_comparison HistoryComparison
	recovery_disk_root string
	recovery_saved bool
	recovery_saved_generation u64
	recovery_notice string
	recovery_baseline []RecoverySource
	recovery_revisions []ConfigRevision
	recovery_confirmed bool
	recovery_generation u64
	recovery_at string
	recovery_store_root string
	rollback_preview RollbackPreview
	pending_rollback ?PendingRollback
	config_status ConfigStatus
	field_baseline []ConfigComponentFields
	field_salt string
	config_baseline []ConfigRevision
	log_filter string
	log_focus_serial u64
	next_log_probe i64
	request_log_ids []string
	request_logs map[string]string
	next_config_probe i64
	browser_handoffs []BrowserHandoff
	process       &os.Process = unsafe { nil }
	phase         Phase
	project       Project
	info          ProjectInfo
	token         string
	lines         []string
	message       string
	deadline      i64
	next_probe    i64
	can_force     bool
	ready_event   bool
	startup_failure bool
	start_timeout i64 = 90000
	stop_timeout  i64 = 5000
}

pub fn new_manager() &Manager {
	return &Manager{}
}

pub fn (mut m Manager) select_project(project Project) ! {
	if !isnil(m.process) { return error('请先停止当前实例。') }
	m.project = project
	m.phase = .stopped
	m.lines = []string{}
	m.reset_log_focus()
	m.message = ''
	m.open_recovery_version()
	m.info = inspect_project(project) or { ProjectInfo{} }
	m.field_salt = crypto_rand.bytes(32)!.hex()
	m.offline_recovery_status()
}

pub fn (mut m Manager) start(project Project, binary string) ! {
	if !isnil(m.process) {
		return error('请先停止当前实例。')
	}
	m.project = project
	m.lines = []string{}
	m.ready_event = false
	m.startup_failure = false
	m.can_force = false
	m.prepare_start(project, binary) or {
		m.phase = .failed
		m.message = err.msg()
		m.log(m.message)
		return err
	}
}

fn (mut m Manager) prepare_start(project Project, binary string) ! {
	if !os.is_executable(binary) { return error('vhttpd 可执行文件不可用，请点击左侧“选择 vhttpd…”重新选择。') }
	if !os.is_dir(project.workdir) { return error('项目工作目录不存在，请确认目录未移动，或重新导入项目。') }
	info := inspect_project(project)!
	baseline := config_revisions(project.config_path)!
	field_salt := crypto_rand.bytes(32)!.hex()
	field_baseline := config_component_fields(project.config_path, baseline, field_salt)!
	if config_revisions(project.config_path)! != baseline { return error('启动期间配置发生变化，请重试。') }
	// Preflight improves diagnostics; the fresh per-launch credential below
	// also prevents a racing unrelated server from satisfying readiness.
	mut probe := net.listen_tcp(.ip, '${url_host(info.admin_host)}:${info.admin_port}') or {
		return error('管理端口 ${info.admin_port} 已被占用；未启动或终止任何实例。')
	}
	probe.close()!
	if info.app_url != '' {
		mut business_probe := net.listen_tcp(.ip, info.app_url.all_after('://')) or {
			return error('业务地址 ${info.app_url} 已被占用或无法绑定；请在配置中调整监听地址或端口后重试。未启动或终止任何实例。')
		}
		business_probe.close()!
	}
	m.project = project
	m.info = info
	m.open_recovery_version()
	m.recovery_store_root = info.state_root
	m.pending_rollback = none
	m.rollback_preview = RollbackPreview{}
	m.config_baseline = baseline
	m.field_baseline = field_baseline
	m.field_salt = field_salt
	m.token = crypto_rand.bytes(32)!.hex()
	m.lines = []string{}
	m.reset_log_focus()
	m.can_force = false
	m.ready_event = false
	m.config_status = ConfigStatus{state: .checking, message: '启动后自动检查配置生效状态…'}
	m.next_config_probe = 0
	m.message = '正在启动，等待管理连接和业务监听就绪；首次初始化可能需要较长时间…'
	m.log('读取项目配置：${project.config_path}')
	m.log('管理 token 使用本次启动的临时凭据；配置文件未修改。')
	mut child := os.new_process(os.real_path(binary))
	child.set_work_folder(project.workdir)
	child.set_args(['--config', project.config_path, '--admin-token', m.token])
	child.set_redirect_stdio_merged()
	child.use_pgroup = true
	child.run()
	m.process = child
	m.phase = .starting
	m.deadline = time.ticks() + m.start_timeout
	m.next_probe = 0
}

pub fn (mut m Manager) stop() {
	if isnil(m.process) || m.phase == .stopping {
		return
	}
	m.phase = .stopping
	m.can_force = false
	m.ready_event = false
	m.message = '正在正常关闭实例…'
	m.log('向宿主拥有的实例发送终止请求。')
	m.process.signal_term()
	m.deadline = time.ticks() + m.stop_timeout
}

pub fn (mut m Manager) force_stop() {
	if isnil(m.process) || !m.can_force {
		return
	}
	m.log('用户要求强制结束本次启动的进程组。')
	m.process.signal_pgkill()
	m.process.wait()
	m.finish(true)
}

pub fn (mut m Manager) clear_logs() {
	m.lines = []string{}
	m.request_logs.clear()
	m.request_log_ids.clear()
}

pub fn (mut m Manager) tick() {
	m.cleanup_browser_handoffs(false)
	m.ready_event = false
	if isnil(m.process) {
		return
	}
	m.read_output()
	if m.phase == .running { m.poll_log_focus() }
	if !m.process.is_alive() {
		m.finish(m.phase == .stopping)
		return
	}
	now := time.ticks()
	if m.phase == .starting {
		if now >= m.deadline {
			m.message = if m.startup_failure { '执行器初始化失败且启动未完成，正在关闭实例；请检查日志。' } else { '启动超时，正在关闭实例；请检查日志。' }
			m.log(m.message)
			m.process.signal_term()
			m.phase = .failed
			m.deadline = now + m.stop_timeout
		} else if now >= m.next_probe {
			m.next_probe = now + 400
			admin_connected := admin_ready(m.info.admin_url, m.token)
			if admin_connected {
				m.message = '管理接口已连接，正在等待业务监听和执行器初始化…'
			}
			if admin_connected && application_listening(m.info.app_url) && m.process.is_alive() {
				if m.startup_failure {
					// Let initialization release its locks before normal shutdown.
					m.phase = .failed
					m.message = '执行器初始化失败，正在关闭本次实例；请修正下方日志中的问题后重新启动。'
					m.process.signal_term()
					m.deadline = now + m.stop_timeout
					return
				}
				m.phase = .running
				m.ready_event = true
				m.message = '实例已就绪。协议配置与调试在浏览器中完成。'
				m.log('管理接口认证通过，实例就绪。')
			}
		}
	}
	if m.phase == .running && now >= m.next_config_probe {
		m.refresh_config_status()
	}
	if m.phase in [.stopping, .failed] && now >= m.deadline && !m.can_force {
		m.can_force = true
		m.message = '实例尚未退出，可点击“强制停止”。'
		m.log(m.message)
	}
}

fn (mut m Manager) read_output() {
	// Bound work per tick even when the child continuously writes logs.
	for _ in 0 .. 16 {
		text := m.process.stdout_read()
		if text == '' { break }
		for line in text.split_into_lines() {
			if line.trim_space() != '' { m.log(line) }
			// The control listener may survive an executor warmup failure.
			if m.phase == .starting && executor_start_failure(line) {
				m.message = '执行器初始化失败，正在完成启动收尾；请修正下方日志中的问题后重新启动。'
				m.log(m.message)
				m.startup_failure = true
			}
		}
	}
}

fn executor_start_failure(line string) bool {
	clean := strip_ansi(line)
	return clean.contains('[ERROR] [vhttpd] logic executor warmup failed:')
		|| clean.contains('[ERROR] [vhttpd] additional logic executor warmup failed pool=')
}

fn (mut m Manager) log(text string) {
	mut clean := strip_ansi(text)
	for secret in [m.token, m.info.config_token] {
		if secret != '' { clean = clean.replace(secret, '[REDACTED]') }
	}
	m.capture_request_log(clean)
	// Keep both line count and each line bounded.
	if clean.len > 1600 { clean = clean[..1600] + '…' }
	m.lines << '${time.now().hhmmss()}  ${clean}'
	if m.lines.len > 150 { m.lines = m.lines[m.lines.len - 150..].clone() }
}

fn application_listening(url string) bool {
	if url == '' { return true }
	address := url.all_after('://')
	mut socket := net.dial_tcp(address) or { return false }
	socket.close() or {}
	return true
}

fn (mut m Manager) finish(expected bool) {
	m.read_output()
	m.process.wait()
	code := m.process.code
	m.process.close()
	m.process = unsafe { nil }
	m.token = ''
	m.pending_rollback = none
	m.rollback_preview = RollbackPreview{}
	m.offline_recovery_status()
	m.can_force = false
	m.ready_event = false
	m.phase = if expected { Phase.stopped } else { Phase.failed }
	m.message = if !expected && m.message.starts_with('执行器初始化失败') {
		'执行器初始化失败，请修正下方日志中的问题后重新启动。'
	} else if expected {
		'实例已停止。'
	} else {
		'实例已退出（退出码 ${code}），请检查日志。'
	}
	m.log(m.message)
}

pub fn (m &Manager) snapshot() Snapshot {
	return Snapshot{
		recovery_history: m.recovery_history_views()
		history_comparison: m.history_comparison
		recovery_saved: m.recovery_saved
		rollback_preview: m.rollback_preview
		config_status: m.config_status
		phase:       m.phase
		pid:         if isnil(m.process) { 0 } else { m.process.pid }
		project:     m.project.config_path
		admin_url:   m.info.admin_url
		app_url:     m.info.app_url
		entry:       m.info.entry
		executor:    m.info.executor
		log_filter: m.log_filter
		log_focus_serial: m.log_focus_serial
		logs:        m.visible_logs()
		message:     m.message
		can_force:   m.can_force
		ready_event: m.ready_event
		token:       m.token
	}
}

pub fn (mut m Manager) shutdown() {
	defer { m.cleanup_browser_handoffs(true) }
	if isnil(m.process) { return }
	m.stop()
	deadline := time.ticks() + m.stop_timeout + 500
	for !isnil(m.process) && time.ticks() < deadline {
		m.tick()
		time.sleep(40 * time.millisecond)
	}
	if !isnil(m.process) {
		// App exit must not orphan its owned process. Normal UI stop never
		// escalates without the explicit force-stop button.
		m.can_force = true
		m.force_stop()
	}
}

pub fn admin_ready(admin_url string, token string) bool {
	mut request := http.Request{
		url:                      admin_url.replace('/admin/ui/', '/admin/runtime')
		read_timeout:             250 * time.millisecond
		write_timeout:            250 * time.millisecond
		max_retries:              1
		allow_redirect:           false
		disable_connection_reuse: true
	}
	request.add_custom_header('x-vhttpd-admin-token', token) or { return false }
	response := request.do() or { return false }
	return response.status_code == 200 && response.body.starts_with('{')
}

pub fn open_browser(url string) ! {
	if !url.starts_with('http://127.0.0.1:') && !url.starts_with('http://localhost:')
		&& !url.starts_with('http://[::1]:') {
		return error('仅允许打开本机管理地址。')
	}
	open_local(url)!
}

pub fn open_local(target string) ! {
	$if macos {
		mut opener := os.new_process('/usr/bin/open')
		opener.set_args([target])
		opener.run()
		opener.wait()
		defer { opener.close() }
		if opener.code != 0 { return error('系统无法打开目标：${target}') }
	} $else {
		return error('当前宿主原型仅交付 macOS。')
	}
}

fn strip_ansi(text string) string {
	mut out := []u8{cap: text.len}
	mut i := 0
	for i < text.len {
		if text[i] == 27 && i + 1 < text.len && text[i + 1] == `[` {
			i += 2
			for i < text.len && !(text[i] >= 64 && text[i] <= 126) { i++ }
			if i < text.len { i++ }
		} else {
			out << text[i]
			i++
		}
	}
	return out.bytestr()
}
