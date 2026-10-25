module main

import host
import time
import ui2

fn test_keyboard_focus_order_skips_unavailable_controls_and_reverses() ! {
	root := ui2.screen(workbench_paper, [
		ui2.view('workbench_sidebar', ui2.rect(0, 0, 200, 500), ui2.BoxStyle{}, [button('nav', 'Navigation', 0, 0, 100, false, true)]),
		ui2.scroll('form', ui2.rect(200, 0, 500, 500), workbench_paper, [
			input('first', '', 'First', 0, 20, 200, true),
			input('disabled', '', 'Unavailable', 0, 70, 200, false),
			ui2.Element{...input('secret', '', 'Password', 0, 700, 200, true), secure: true},
			button('submit', 'Connect', 0, 760, 100, true, true),
		])])
	targets := focus_targets(root)
	assert targets.map(it.id) == ['first', 'secret', 'submit']
	forward := next_focus_target(targets, 'first', false) or { return error('missing forward focus') }
	assert forward.id == 'secret'
	reverse := next_focus_target(targets, 'secret', true) or { return error('missing reverse focus') }
	assert reverse.id == 'first'
	wrap := next_focus_target(targets, 'submit', false) or { return error('missing wrap focus') }
	assert wrap.id == 'first'
	back := next_focus_target(targets, 'first', true) or { return error('missing backward wrap') }
	assert back.id == 'submit'
	assert targets[1].scroll == 'form' && targets[1].frame.y == 700
	assert root.children[1].children[0].submit_id == 'form_submit'
}

fn test_desktop_details_fit_compact_windows() ! {
	mut app := unsafe { workshop }
	app.server_busy = false
	app.server_snapshot = host.ServerSnapshot{}
	app.select_server(host.RemoteServer{id: 'ab'.repeat(12), name: 'Fixture', ssh_host: 'fixture', auth_method: 'password'})
	for width in [488.0, 708.0, 1000.0] {
		ui2.validate_element_tree(ui2.screen(workbench_paper, remote_servers_view(app, width)))!
		ui2.validate_element_tree(ui2.screen(workbench_paper, runtime_settings_view(app, width)))!
	}
	for row in server_detail_view(app, 320) { assert row.frame.x + row.frame.width <= 320 }
	app.new_error = ''
	app.creating = false
	for row in new_project_view(app, 0, 488) {
		if row.id.ends_with('new_submit_container') { assert row.frame.y + row.frame.height < 660 }
	}
}

fn test_leaving_new_project_does_not_disable_future_navigation() {
	mut app := unsafe { workshop }
	app.creating = false
	app.server_busy = false
	app.server_snapshot = host.ServerSnapshot{}
	app.remote_snapshot = host.RemoteSnapshot{}
	app.new_project = true
	handle_event('server_home')
	assert !app.new_project && app.show_remote
	app.show_remote = false
	app.new_project = true
	workbench_physical_key(ui2.KeyEvent{code: .escape})
	assert !app.new_project
}

fn test_remote_server_and_runtime_target_states() ! {
	mut app := unsafe { workshop }
	app.server_worker = host.ServerWorker{}
	app.server_snapshot = host.ServerSnapshot{}
	app.server_busy = false
	app.remote_servers = []host.RemoteServer{}
	app.remote_id = ''
	ui2.validate_element_tree(ui2.screen(workbench_paper, remote_servers_view(app, 700)))!
	app.select_server(host.RemoteServer{id: 'cd'.repeat(12), name: 'Linux', ssh_host: 'fixture'})
	rows := remote_servers_view(app, 700)
	assert !rows.any(it.id == 'remote_token' || it.id == 'remote_admin_port')
	ui2.validate_element_tree(ui2.screen(workbench_paper, rows))!
	app.remote_auth = 'password'
	app.remote_password = 'ephemeral-test'
	app.server_command(.connect, '')
	command := <-app.server_worker.commands
	assert command.password == 'ephemeral-test'
	assert app.remote_password == ''
	app.server_busy = false
	app.remote_servers = [app.server_form()]
	app.runtime_server_id = app.remote_id
	ui2.validate_element_tree(ui2.screen(workbench_paper, runtime_settings_view(app, 700)))!
	assert runtime_test_enabled(runtime_settings_view(app, 700), 'server_go_connect')!
	app.server_snapshot = host.ServerSnapshot{server: app.server_form(), server_id: app.remote_id, connected: true, platform: 'linux-arm64', root: '/home/fixture/.local/share/vhttpd-workbench'}
	assert runtime_test_enabled(runtime_settings_view(app, 700), 'server_install')!
	app.server_snapshot = host.ServerSnapshot{...app.server_snapshot, version: '0.1.0'}
	assert !runtime_test_enabled(runtime_settings_view(app, 700), 'server_install')!
	assert runtime_test_enabled(runtime_settings_view(app, 700), 'server_create')!
	ui2.validate_element_tree(ui2.screen(workbench_paper, runtime_settings_view(app, 700)))!
	app.remote_servers = [host.RemoteServer{...app.remote_servers[0], ssh_host: 'changed-host'}]
	assert runtime_test_enabled(runtime_settings_view(app, 700), 'server_go_connect')!
	app.server_snapshot = host.ServerSnapshot{}
	app.remote_servers = []host.RemoteServer{}
	app.runtime_server_id = ''
	app.remote_server_id = ''
}

fn test_unknown_and_changed_host_fingerprint_screens() ! {
	mut app := unsafe { workshop }
	app.remote_id = 'ab'.repeat(12)
	app.remote_host = 'test-host'
	app.remote_worker = host.RemoteWorker{}
	app.remote_snapshot = host.RemoteSnapshot{profile_id: app.remote_id, busy: true, host_key: host.RemoteHostKey{id: 'challenge', algorithm: 'ED25519', fingerprint: 'SHA256:fixture'}}
	app.remote_connected_form = app.remote_form()
	ui2.validate_element_tree(ui2.screen(workbench_paper, remote_instances_view(app, 700)))!
	assert runtime_test_enabled(remote_instances_view(app, 700), 'remote_trust_host')!
	handle_event('remote_trust_host')
	command := <-app.remote_worker.commands
	assert command.action == .confirm_host_key && command.host_key_id == 'challenge'
	assert command.password == ''
	assert app.remote_snapshot.host_key.id == ''
	app.remote_snapshot = host.RemoteSnapshot{profile_id: app.remote_id, host_key_changed: true, host_key: host.RemoteHostKey{fingerprint: 'SHA256:changed'}}
	ui2.validate_element_tree(ui2.screen(workbench_paper, remote_instances_view(app, 700)))!
	assert !runtime_test_enabled(remote_instances_view(app, 700), 'remote_open')!
	app.remote_snapshot = host.RemoteSnapshot{}
}

fn test_password_auth_form_and_ephemeral_connect_command() ! {
	mut app := unsafe { workshop }
	app.remote_id = 'ab'.repeat(12)
	app.remote_worker = host.RemoteWorker{}
	app.remote_snapshot = host.RemoteSnapshot{}
	handle_event('remote_auth_password')
	assert app.remote_auth == 'password'
	rows := remote_instances_view(app, 700)
	ui2.validate_element_tree(ui2.screen(workbench_paper, rows))!
	mut password_secure := false
	for row in rows {
		if row.id == 'remote_password' { password_secure = row.secure }
	}
	assert password_secure
	app.remote_password = 'ephemeral-fixture-secret'
	handle_event('remote_auth_password')
	assert app.remote_password == 'ephemeral-fixture-secret'
	app.send_remote(.connect)
	command := <-app.remote_worker.commands
	assert command.password == 'ephemeral-fixture-secret'
	assert command.profile.auth_method == 'password'
	assert app.remote_password == ''
	app.remote_snapshot = host.RemoteSnapshot{}
	app.remote_password = 'discard-fixture'
	handle_event('remote_auth_key')
	assert app.remote_auth == 'key' && app.remote_password == ''
}

fn test_host_refresh_loop_wakes_and_stops_without_ui2_timers() {
	stop := chan bool{cap: 1}
	wakes := chan bool{cap: 4}
	done := chan bool{cap: 1}
	spawn fn [stop, wakes, done] () {
		workbench_refresh_loop(stop, fn [wakes] () { wakes <- true })
		done <- true
	}()
	select {
		_ := <-wakes {}
		3 * time.second { assert false, 'host refresh loop did not wake' }
	}
	stop <- true
	select {
		_ := <-done {}
		3 * time.second { assert false, 'host refresh loop did not stop' }
	}
}

fn test_window_build_consumes_worker_status_on_ui_thread() ! {
	mut app := unsafe { workshop }
	previous_worker := app.worker
	previous_snapshot := app.snapshot
	previous_sequence := app.sequence
	app.worker = host.Worker{}
	app.sequence = 0
	app.worker_started = true
	app.worker.snapshots <- host.Snapshot{sequence: 1, phase: .failed}
	defer {
		app.worker_started = false
		app.worker = previous_worker
		app.snapshot = previous_snapshot
		app.sequence = previous_sequence
	}
	ui2.validate_element_tree(build_window())!
	assert app.snapshot.phase == .failed
}

fn test_shared_relay_screens_and_use_project_command() ! {
	mut app := unsafe { workshop }
	app.show_shared_relays = true
	app.shared_relays = []host.SharedRelay{}
	app.projects = []host.Project{}
	ui2.validate_element_tree(build_window())!
	handle_event('shared_new')
	app.shared_name = 'Hub'
	app.shared_url = 'ws://127.0.0.1:1234/vhttpd/relay'
	app.shared_token = 'private-token'
	app.shared_relays = [app.shared_form()]
	app.projects = [host.Project{ name: 'app', config_path: '/tmp/app/vhttpd.toml', workdir: '/tmp/app' }]
	app.selected = 0
	app.worker = host.Worker{}
	app.snapshot = host.Snapshot{ phase: .running }
	ui2.validate_element_tree(build_window())!
	handle_event('shared_use')
	command := <-app.worker.commands
	assert command.action == .use_shared_relay
	assert command.shared_relay.token == 'private-token'
	app.shared_testing = true
	ui2.validate_element_tree(build_window())!
	app.shared_testing = false
	app.show_shared_relays = false
}

fn test_empty_new_project_and_failure_screens_have_valid_element_trees() ! {
	mut app := unsafe { workshop }
	app.projects = []host.Project{}
	ui2.validate_element_tree(build_window())!
	app.new_project = true
	app.new_name = 'first-app'
	app.new_parent = '/tmp'
	for creating in [false, true] {
		app.creating = creating
		ui2.validate_element_tree(build_window())!
	}
	app.creating = false
	app.new_error = '项目目录已经存在，请更换名称。'
	ui2.validate_element_tree(build_window())!
	app.new_project = false
}

fn test_running_pending_and_offline_recovery_screens_can_refresh() ! {
	mut app := unsafe { workshop }
	project := host.Project{ name: 'app', config_path: '/tmp/app/vhttpd.toml', workdir: '/tmp/app' }
	app.projects = [project]
	app.selected = 0
	for phase in [host.Phase.stopped, .starting, .running, .stopping, .failed] {
		app.snapshot = host.Snapshot{ phase: phase }
		for state in [host.ConfigState.unknown, .checking, .effective, .pending, .unavailable] {
			app.config_statuses[project.config_path] = host.ConfigStatus{ state: state, pending: state == .pending, recovery_available: true }
			ui2.validate_element_tree(build_window())!
		}
	}
	app.show_config_diff = true
	ui2.validate_element_tree(build_window())!
	app.show_config_diff = false
	app.show_history = true
	ui2.validate_element_tree(build_window())!
	app.show_history = false
	app.show_rollback = true
	ui2.validate_element_tree(build_window())!
	app.show_rollback = false
}

fn test_restart_returns_to_workbench_and_immediately_shows_progress() {
	mut app := unsafe { workshop }
	app.worker = host.Worker{}
	app.snapshot = host.Snapshot{ phase: .running, pid: 1 }
	app.show_config_diff = true
	app.show_rollback = true
	app.show_history = true
	handle_event('apply_restart')
	assert app.restart_after
	assert app.snapshot.phase == .stopping
	assert !app.show_config_diff && !app.show_rollback && !app.show_history
	command := <-app.worker.commands
	assert command.action == .stop
}

fn test_status_copy_never_claims_unconfirmed_configuration_is_effective() {
	for phase in [host.Phase.stopped, .starting, .running, .stopping, .failed] {
		for state in [host.ConfigState.unknown, .checking, .effective, .pending, .unavailable] {
			_, _, tone := config_status_copy(host.Snapshot{ phase: phase }, host.ConfigStatus{ state: state, pending: state == .pending })
			assert (tone == 'good') == (phase == .running && state == .effective)
		}
	}
	// A failed check can retain earlier differences, but cannot confirm them.
	title, _, tone := config_status_copy(host.Snapshot{ phase: .running }, host.ConfigStatus{ state: .unavailable, pending: true })
	assert title == '生效状态未确认'
	assert tone == 'warning'
}

fn test_restart_stop_result_does_not_cancel_new_instance_browser_login() {
	mut app := unsafe { workshop }
	app.projects = [host.Project{ name: 'restart', config_path: '/tmp/restart/vhttpd.toml', workdir: '/tmp/restart' }]
	app.selected = 0
	app.worker = host.Worker{}
	app.snapshot = host.Snapshot{ phase: .stopped, message: '实例已停止。' }
	app.restart_after = true
	app.request_open = false
	app.continue_lifecycle(app.snapshot)
	assert app.snapshot.phase == .starting
	assert app.request_open
	start := <-app.worker.commands
	assert start.action == .start
	app.continue_lifecycle(host.Snapshot{ phase: .starting, pid: 10 })
	assert app.request_open
	app.continue_lifecycle(host.Snapshot{ phase: .running, pid: 10 })
	assert !app.request_open
	open := <-app.worker.commands
	assert open.action == .open_admin
}

fn test_runtime_settings_disable_switches_while_project_runs_and_resume_missing_runtime() ! {
	mut app := unsafe { workshop }
	defer {
		app.show_runtime = false
		app.runtime_checked = false
		app.runtime_busy = false
		app.runtime_resume_start = false
		app.runtime_info = host.RuntimeInfo{}
	}
	app.show_runtime = true
	app.runtime_checked = true
	app.runtime_info = host.RuntimeInfo{ path: '/missing/vhttpd', message: '运行包缺失' }
	app.binary = '/missing/vhttpd'
	app.snapshot = host.Snapshot{ phase: .stopped }
	app.projects = [host.Project{ name: 'pending', config_path: '/tmp/pending.toml', workdir: '/tmp' }]
	app.selected = 0
	app.worker = host.Worker{}
	app.launch()
	assert app.show_runtime && app.runtime_resume_start
	assert app.snapshot.phase != .starting
	ui2.validate_element_tree(build_window())!
	app.runtime_results <- RuntimeResult{ path: '/installed/vhttpd', select_path: true, downloaded: true, info: host.RuntimeInfo{ path: '/installed/vhttpd', version: '0.1.0', ready: true, source: '已下载' } }
	app.poll_runtime()
	selected := <-app.worker.commands
	assert selected.action == .select_project
	command := <-app.worker.commands
	assert command.action == .start && command.binary == '/installed/vhttpd'
	assert app.request_open && !app.show_runtime
	app.snapshot = host.Snapshot{ phase: .running, pid: 123 }
	rows := runtime_settings_view(app, 700)
	assert !runtime_test_enabled(rows, 'runtime_download')!
	assert !runtime_test_enabled(rows, 'binary')!
	app.runtime_busy = true
	app.new_project = false
	app.show_new_project()
	assert !app.new_project && app.show_runtime
	app.runtime_results <- RuntimeResult{ error: 'SHA256 不一致，未安装。' }
	app.poll_runtime()
	assert app.binary == '/installed/vhttpd' && app.runtime_info.ready
	assert app.runtime_error && !app.runtime_busy
}

fn runtime_test_enabled(elements []ui2.Element, id string) !bool {
	for element in elements {
		if element.id == id { return element.enabled }
		if element.children.len > 0 {
			enabled := runtime_test_enabled(element.children, id) or { continue }
			return enabled
		}
	}
	return error('element not found: ' + id)
}

fn test_remote_instance_form_and_navigation_are_valid() ! {
	mut app := unsafe { workshop }
	app.show_remote = true
	app.remote_id = 'ab'.repeat(12)
	app.remote_admin_port = '2018'
	app.remote_profiles = [host.RemoteProfile{id: app.remote_id, name: '测试实例', ssh_host: 'dev-server', token: 'private'}]
	for connected in [false, true] {
		app.remote_snapshot = host.RemoteSnapshot{profile_id: app.remote_id, connected: connected, instance: host.RemoteInstance{version: 'test', ready: connected, manual_restart: true}}
		ui2.validate_element_tree(build_window())!
	}
	app.remote_name = '测试实例'
	app.remote_host = 'dev-server'
	app.remote_token = 'private'
	app.remote_connected_form = app.remote_form()
	assert runtime_test_enabled(remote_instances_view(app, 700), 'remote_open')!
	app.remote_host = 'another-server'
	assert !runtime_test_enabled(remote_instances_view(app, 700), 'remote_open')!
	assert !runtime_test_enabled(remote_instances_view(app, 700), 'remote_restart')!
	app.remote_worker = host.RemoteWorker{}
	app.send_remote(.connect)
	command := <-app.remote_worker.commands
	assert command.action == .connect && command.profile.ssh_host == 'another-server'
	assert command.sequence == app.remote_sequence && app.remote_snapshot.busy
	app.remote_snapshot = host.RemoteSnapshot{busy: true, message: '正在重启…'}
	ui2.validate_element_tree(build_window())!
	handle_event('runtime')
	assert !app.show_remote
	app.show_runtime = false
	app.show_remote = true
	handle_event('shared_relays')
	assert !app.show_remote
	app.show_shared_relays = false
	app.show_remote = false
}
