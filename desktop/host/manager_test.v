module host

import net
import os
import time

fn test_project_parser_uses_includes_and_resolves_entry() ! {
	dir := fixture_dir('project')!
	defer { os.rmdir_all(dir) or {} }
	os.write_file(os.join_path(dir, 'engine.toml'), '[engines.app]\nkind = "vjsx"\nentry = "main.mts"\nruntime_profile = "node"\n')!
	path := os.join_path(dir, 'vhttpd.toml')
	os.write_file(path, 'version = 2\ninclude = ["engine.toml"]\n[listeners.admin]\nprotocol = "http"\nhost = "127.0.0.1"\nport = 19999\n[control]\nlistener = "listener:admin"\ntoken = "test-token"\n')!
	p := project_from_file(path, dir)!
	info := inspect_project(p)!
	assert info.admin_url == 'http://127.0.0.1:19999/admin/ui/'
	assert info.executor == 'vjsx'
	assert info.entry == os.join_path(dir, 'main.mts')
	registry := os.join_path(dir, 'registry.json')
	save_projects(registry, [p])!
	assert load_projects(registry, [])! == [p]
}

fn test_busy_port_is_not_adopted_or_killed() ! {
	dir := fixture_dir('busy')!
	defer { os.rmdir_all(dir) or {} }
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { listener.close() or {} }
	port := listener.addr()!.port()!
	p := fixture_project(dir, int(port))!
	mut manager := new_manager()
	manager.start(p, '/usr/bin/true') or {
		assert err.msg().contains('已被占用')
		assert manager.snapshot().pid == 0
		assert manager.snapshot().phase == .failed
		assert manager.snapshot().logs.contains('已被占用')
		return
	}
	assert false, 'Busy admin port must refuse startup'
}

fn test_timeout_duplicate_start_force_cleanup_and_log_redaction() ! {
	dir := fixture_dir('timeout')!
	defer { os.rmdir_all(dir) or {} }
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := listener.addr()!.port()!
	listener.close()!
	p := fixture_project(dir, int(port))!
	fixture := os.join_path(dir, 'fake-vhttpd')
	os.write_file(fixture, '#!/usr/bin/env python3\nimport signal,sys,time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nprint(sys.argv[-1], flush=True)\nwhile True: time.sleep(0.05)\n')!
	os.chmod(fixture, 0o755)!
	mut manager := new_manager()
	manager.start_timeout = 15000
	manager.stop_timeout = 150
	defer { manager.shutdown() }
	manager.start(p, fixture)!
	pid := manager.snapshot().pid
	secret := manager.snapshot().token
	assert pid > 0
	manager.start(p, fixture) or { assert manager.snapshot().pid == pid }
	// Wait for the fixture's signal handler to be installed before provoking
	// a timeout. Interpreter startup can exceed 700ms during concurrent builds.
	fixture_deadline := time.ticks() + 10000
	for !manager.snapshot().logs.contains('[REDACTED]') && time.ticks() < fixture_deadline {
		manager.tick()
		time.sleep(40 * time.millisecond)
	}
	assert manager.snapshot().logs.contains('[REDACTED]'), 'Fixture did not become ready'
	manager.deadline = time.ticks() - 1
	deadline := time.ticks() + 4000
	for !manager.snapshot().can_force && time.ticks() < deadline {
		manager.tick()
		time.sleep(40 * time.millisecond)
	}
	assert manager.snapshot().phase == .failed
	assert manager.snapshot().can_force
	assert manager.snapshot().logs.contains('[REDACTED]')
	assert !manager.snapshot().logs.contains(secret)
	manager.force_stop()
	assert manager.snapshot().pid == 0
	assert manager.snapshot().phase == .stopped
	assert manager.snapshot().token == ''
}

fn test_unexpected_exit_is_reported_and_process_reaped() ! {
	dir := fixture_dir('exit')!
	defer { os.rmdir_all(dir) or {} }
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := listener.addr()!.port()!
	listener.close()!
	mut manager := new_manager()
	defer { manager.shutdown() }
	manager.start(fixture_project(dir, int(port))!, '/usr/bin/true')!
	deadline := time.ticks() + 2000
	for manager.snapshot().pid > 0 && time.ticks() < deadline {
		manager.tick()
		time.sleep(30 * time.millisecond)
	}
	assert manager.snapshot().phase == .failed
	assert manager.snapshot().pid == 0
	assert manager.snapshot().logs.contains('退出码')
}

fn fixture_project(dir string, port int) !Project {
	path := os.join_path(dir, 'vhttpd.toml')
	os.write_file(path, '[admin]\nhost = "127.0.0.1"\nport = ${port}\ntoken = "test-token"\n')!
	return project_from_file(path, dir)!
}

fn fixture_dir(label string) !string {
	path := os.join_path(os.temp_dir(), 'workbench-${label}-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(path)!
	return os.real_path(path)
}

fn test_cold_start_longer_than_old_deadline_can_become_ready() ! {
	dir := fixture_dir('cold-start')!
	defer { os.rmdir_all(dir) or {} }
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := listener.addr()!.port()!
	listener.close()!
	fixture := os.join_path(dir, 'fake-vhttpd')
	os.write_file(fixture, '#!/usr/bin/env python3\nimport time\nfrom http.server import BaseHTTPRequestHandler, HTTPServer\ntime.sleep(16)\nclass Handler(BaseHTTPRequestHandler):\n def do_GET(self):\n  self.send_response(200); self.end_headers(); self.wfile.write(b"{}")\n def log_message(self,*args): pass\nHTTPServer(("127.0.0.1",${port}),Handler).serve_forever()\n')!
	os.chmod(fixture, 0o755)!
	mut manager := new_manager()
	defer { manager.shutdown() }
	path := os.join_path(dir, 'vhttpd.toml')
	os.write_file(path, 'version=2\n[control]\nlistener="listener:admin"\ntoken="test-token"\n[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport=${port}\n')!
	project := project_from_file(path, dir)!
	assert inspect_project(project)!.app_url == ''
	manager.start(project, fixture)!
	deadline := time.ticks() + 30000
	for manager.snapshot().phase == .starting && time.ticks() < deadline {
		manager.tick()
		time.sleep(80 * time.millisecond)
	}
	assert manager.snapshot().phase == .running, manager.snapshot().logs
}

fn test_busy_business_port_has_actionable_failure_without_starting_a_child() ! {
	dir := fixture_dir('business-busy')!
	defer { os.rmdir_all(dir) or {} }
	mut web := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { web.close() or {} }
	port := web.addr()!.port()!
	mut admin := net.listen_tcp(.ip, '127.0.0.1:0')!
	admin_port := admin.addr()!.port()!
	admin.close()!
	path := os.join_path(dir, 'vhttpd.toml')
	os.write_file(path, 'version=2\n[control]\nlistener="listener:admin"\ntoken="test-token"\n[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport=${admin_port}\n[listeners.web]\nprotocol="http"\nhost="0.0.0.0"\nport=${port}\n[adapters.reply]\nkind="fixed-response"\noptions.body="ok"\n[[pipelines]]\nid="web-route"\ningress="listener:web"\negress="adapter:reply"\n')!
	project := project_from_file(path, dir)!
	assert inspect_project(project)!.app_url == 'http://127.0.0.1:${port}'
	mut manager := new_manager()
	manager.start(project, '/usr/bin/true') or {
		assert err.msg().contains('业务地址') && err.msg().contains('未启动')
		assert manager.snapshot().pid == 0
		return
	}
	assert false, 'Busy business listener must not start a child'
}

fn test_preflight_failure_can_retry_without_reimporting_or_losing_project() ! {
	dir := fixture_dir('retry')!
	defer { os.rmdir_all(dir) or {} }
	mut occupied := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := occupied.addr()!.port()!
	project := fixture_project(dir, int(port))!
	mut manager := new_manager()
	defer { manager.shutdown() }
	manager.select_project(project)!
	manager.start(project, '/usr/bin/true') or {
		assert manager.snapshot().phase == .failed
		assert manager.snapshot().pid == 0
	}
	assert manager.snapshot().phase == .failed
	occupied.close()!
	manager.start(project, '/usr/bin/true')!
	assert manager.snapshot().phase == .starting
	assert manager.snapshot().pid > 0
	assert manager.snapshot().project == project.config_path
	assert !manager.snapshot().logs.contains('已被占用')
}

fn test_executor_warmup_failure_recognizes_real_colored_diagnostics_only() {
	assert executor_start_failure('2026-10-18 [\x1b[31mERROR\x1b[39m] [vhttpd] logic executor warmup failed: syntax error')
	assert executor_start_failure('[ERROR] [vhttpd] additional logic executor warmup failed pool=app kind=vjsx: missing entry')
	assert !executor_start_failure('[INFO ] request path=/warmup failed status=500')
	assert !executor_start_failure('[ERROR] business handler failed')
}
