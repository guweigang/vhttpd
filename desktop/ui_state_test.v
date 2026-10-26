module main

import host
import os
import json2 as json
import time
import ui2

fn test_runtime_version_picker_requires_explicit_compatible_selection() ! {
	mut app := unsafe { workshop }
	app.environment_id = ''
	app.runtime_server_id = ''
	app.runtime_busy = false
	app.runtime_catalog_busy = false
	app.snapshot = host.Snapshot{}
	app.runtime_selected_tag = ''
	app.runtime_downloads = [host.RuntimeDownload{tag: 'v0.1.0-dev.gaaaaaaaaaaaa', channel: 'development', platform: 'macos-arm64', published_at: '2026-10-25T00:00:00Z'}]
	assert !app.can_install_selected_runtime()
	app.handle_runtime_catalog_event('runtime_release_0')
	assert app.can_install_selected_runtime()
	for width in [320.0, 510.0] { ui2.validate_element_tree(ui2.screen(workbench_paper, runtime_downloads_view(app, width)))! }
	app.snapshot = host.Snapshot{pid: 123, phase: .running}
	assert !app.can_install_selected_runtime()
	app.snapshot = host.Snapshot{}
	app.runtime_server_id = 'different-server'
	assert !app.can_install_selected_runtime()
	app.runtime_server_id = ''
	app.runtime_downloads = []host.RuntimeDownload{}
	app.runtime_selected_tag = ''
}

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
	app.environment_id = ''
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
	app.environment_id = ''
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
	app.environment_id = ''
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
	app.server_snapshot = host.ServerSnapshot{...app.server_snapshot, version: '0.1.0', runtimes: [host.RemoteRuntime{id: 'legacy', version: '0.1.0', path: '/fixture/runtime'}]}
	assert runtime_test_enabled(runtime_settings_view(app, 700), 'server_install')!
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
	app.environment_id = ''
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
	app.environment_id = ''
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
	app.environment_id = ''
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
	app.environment_id = ''
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
	app.environment_id = ''
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
	app.environment_id = ''
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
	app.environment_id = ''
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
	app.environment_id = ''
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
	app.environment_id = ''
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
	app.environment_id = ''
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

fn test_environment_project_isolation_and_actions_follow_the_selected_host() ! {
	mut app := &Workshop{}
	a := host.RemoteServer{id: 'server-a', name: 'A', ssh_host: 'a.example', ssh_user: 'alice'}
	b := host.RemoteServer{id: 'server-b', name: 'B', ssh_host: 'b.example', ssh_user: 'bob'}
	app.remote_servers = [a, b]
	app.remote_profiles = [
		host.RemoteProfile{id: 'a1', server_id: a.id, name: 'API A', ssh_host: 'old.example', token: 'private-a'},
		host.RemoteProfile{id: 'a2', server_id: a.id, name: 'Web A'},
		host.RemoteProfile{id: 'b1', server_id: b.id, name: 'API B'},
		host.RemoteProfile{id: 'legacy', name: 'Existing SSH', ssh_host: 'legacy.example'},
	]
	app.snapshot = host.Snapshot{pid: 123, phase: .running}
	app.selected = 2
	app.open_environment_projects(a.id)
	assert app.environment_profiles().map(it.id) == ['a1', 'a2']
	assert app.remote_host == 'a.example' && app.remote_server_id == a.id
	assert app.remote_token == 'private-a'
	assert app.show_remote && !app.show_servers
	// Navigation must not stop the local process or silently select a local project.
	assert app.snapshot.pid == 123 && app.selected == 2
	app.handle_environment_event('new')
	assert app.show_runtime && !app.new_project
	assert app.runtime_server_id == a.id && app.server_form() == a
	app.handle_server_event('runtime_target_' + b.id)
	assert app.environment_id == b.id && app.server_form() == b
	assert app.environment_profiles().map(it.id) == ['b1']
	app.handle_remote_event('remote_select_a2')
	assert app.environment_id == a.id && app.remote_id == 'a2' && app.show_remote
	assert app.handle_environment_event('stop')
	assert app.snapshot.pid == 123
	app.open_environment_projects('')
	assert app.environment_profiles().len == 0 && !app.show_remote && app.runtime_server_id == ''
	assert app.snapshot.pid == 123 && app.selected == 2
	app.open_environment_projects('profile:legacy')
	assert app.environment_profiles().map(it.id) == ['legacy']
	// Removing a server record must not hide its retained instance connections.
	app.remote_servers = []host.RemoteServer{}
	assert app.environment_choices().any(it.id == a.id)
	app.open_environment_projects(a.id)
	assert app.environment_profiles().len == 2
}

fn test_environment_and_remote_tunnel_summary_layouts() ! {
	mut app := &Workshop{}
	app.remote_servers = [host.RemoteServer{id: 'a', name: 'Same', ssh_host: 'a.example'}, host.RemoteServer{id: 'b', name: 'Same', ssh_host: 'b.example'}]
	app.remote_profiles = [host.RemoteProfile{id: 'project-a', server_id: 'a', name: 'Remote project', ssh_host: 'a.example', token: 'must-not-appear'}]
	app.open_environment_projects('a')
	app.remote_snapshot = host.RemoteSnapshot{profile_id: 'project-a', connected: true, admin_url: 'http://127.0.0.1:54321/admin/ui/', instance: host.RemoteInstance{version: '0.1.0', platform: 'linux-amd64', ready: true}}
	app.remote_connected_form = app.remote_form()
	choices := app.environment_choices()
	assert choices[1].title != choices[2].title
	assert app.environment_version_label() == '远端 vhttpd 0.1.0'
	for width in [320.0, 510.0] {
		ui2.validate_element_tree(ui2.screen(workbench_paper, remote_instances_view(app, width)))!
		ui2.validate_element_tree(ui2.screen(workbench_paper, [app.environment_selector()]))!
	}
	app.set_environment('b')
	assert app.environment_version_label() == '远端 · 未连接'
}

fn test_full_window_environment_navigation_has_unique_control_ids() ! {
	mut app := unsafe { workshop }
	app.worker_started = false
	app.creating = false
	app.new_project = false
	app.runtime_busy = false
	app.server_busy = false
	app.server_snapshot = host.ServerSnapshot{}
	app.remote_snapshot = host.RemoteSnapshot{}
	app.snapshot = host.Snapshot{}
	app.remote_servers = [host.RemoteServer{id: 'environment-a', name: 'A', ssh_host: 'a.example'}, host.RemoteServer{id: 'environment-b', name: 'B', ssh_host: 'b.example'}]
	app.remote_profiles = [host.RemoteProfile{id: 'project-a', server_id: 'environment-a', name: 'API A', ssh_host: 'a.example'}, host.RemoteProfile{id: 'project-b', server_id: 'environment-b', name: 'API B', ssh_host: 'b.example'}]
	for environment in ['', 'environment-a', 'environment-b'] {
		app.open_environment_projects(environment)
		ui2.validate_element_tree(build_window())!
		app.environment_menu = ui2.DropdownMenuState{open: true}
		ui2.validate_element_tree(ui2.dropdown_menu(ui2.DropdownMenuConfig{id: 'environment_menu', state: app.environment_menu, items: app.environment_menu_items(), anchor: ui2.rect(16, 82, 180, 34), window: ui2.rect(0, 0, 980, 740), width: 260})!)!
		step := ui2.dropdown_menu_update('environment_menu', app.environment_menu_items(), app.environment_menu, ui2.dropdown_menu_item_action('environment_menu', [1])) or { return error('environment selection not handled') }
		app.apply_environment_menu(step)
		assert app.environment_id == 'environment-a' && !app.environment_menu.open
		app.open_environment_projects(environment)
		if environment != '' {
			assert app.handle_environment_event('remote_create_project')
			assert app.show_runtime && app.runtime_server_id == environment
			ui2.validate_element_tree(build_window())!
			app.show_runtime = false
			app.show_remote = true
			app.show_servers = true
			ui2.validate_element_tree(build_window())!
		}
	}
	app.open_environment_projects('')
}

fn test_server_completion_refreshes_projects_even_when_creation_failed() ! {
	old := os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR')
	dir := os.join_path(os.temp_dir(), 'vhttpd-project-refresh-${time.now().unix_micro()}')
	os.mkdir_all(dir)!
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', dir, true)
	defer {
		if value := old { os.setenv('VHTTPD_DESKTOP_DATA_DIR', value, true) } else { os.unsetenv('VHTTPD_DESKTOP_DATA_DIR') }
		os.rmdir_all(dir) or {}
	}
	mut app := &Workshop{}
	app.environment_id = 'server-a'
	app.server_sequence = 3
	app.server_busy = true
	app.server_snapshot = host.ServerSnapshot{sequence: 3, busy: true, connected: true, server_id: 'server-a'}
	profile := host.RemoteProfile{id: 'ab'.repeat(12), server_id: 'server-a', name: 'hello-vjsx', ssh_host: 'fixture', token: 'fixture-only'}
	host.save_remote_profiles([profile])!
	// The remote command can fail after persisting a retryable instance locally.
	app.server_worker.snapshots <- host.ServerSnapshot{sequence: 3, connected: true, server_id: 'server-a', error: true, message: 'creation failed'}
	app.poll_server()
	assert !app.server_busy
	assert app.environment_profiles().map(it.id) == [profile.id]
	assert app.server_snapshot.error
	// A read error must preserve visible projects and expose an error state.
	os.write_file(os.join_path(dir, 'remote-instances.json'), '{invalid')!
	app.reload_remote_profiles()
	assert app.remote_profiles_error != ''
	assert app.environment_profiles().len == 1
	os.write_file(os.join_path(dir, 'remote-instances.json'), json.encode([profile]))!
	app.reload_remote_profiles()
	assert app.remote_profiles_error == ''
}

fn test_remote_project_connect_discovers_credentials_and_reuses_server_session() ! {
	old := os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR')
	dir := os.join_path(os.temp_dir(), 'vhttpd-connect-sync-${time.now().unix_micro()}')
	os.mkdir_all(dir)!
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', dir, true)
	defer {
		if value := old { os.setenv('VHTTPD_DESKTOP_DATA_DIR', value, true) } else { os.unsetenv('VHTTPD_DESKTOP_DATA_DIR') }
		os.rmdir_all(dir) or {}
	}
	server := host.RemoteServer{id: 'ab'.repeat(12), name: 'Server', ssh_host: 'fixture', auth_method: 'password'}
	cached := host.RemoteProfile{id: 'cd'.repeat(12), server_id: server.id, name: 'App', ssh_host: server.ssh_host, auth_method: 'password', token: 'stale-cache'}
	mut app := &Workshop{}
	app.remote_servers = [server]
	app.remote_profiles = [cached]
	app.select_remote_profile(cached)
	app.remote_password = 'session-only-password'
	app.connect_remote_project(cached)
	command := <-app.server_worker.commands
	assert command.action == .connect && command.server.id == server.id
	assert command.password == 'session-only-password'
	assert app.remote_password == '' && app.remote_pending_connect == cached.id
	app.server_worker.snapshots <- host.ServerSnapshot{sequence: command.sequence, server: server, server_id: server.id, busy: true, host_key: host.RemoteHostKey{id: 'first-host', fingerprint: 'SHA256:fixture'}}
	app.poll_server()
	assert app.show_servers && app.remote_pending_connect == cached.id
	assert app.server_snapshot.host_key.id == 'first-host'
	discovered := host.RemoteProfile{...cached, token: 'actual-remote-token', config_path: '/remote/app/vhttpd.toml'}
	host.save_remote_profiles([discovered])!
	app.server_worker.snapshots <- host.ServerSnapshot{sequence: command.sequence, server: server, server_id: server.id, connected: true, control_path: '/fixture/control', discovery_revision: 1, projects: [discovered]}
	app.poll_server()
	connect := <-app.remote_worker.commands
	assert connect.action == .connect && connect.profile.token == discovered.token
	assert connect.profile.config_path == discovered.config_path
	assert connect.control_path == '/fixture/control' && connect.password == ''
	assert app.remote_pending_connect == ''
}

fn failure_test_element(elements []ui2.Element, id string) !ui2.Element {
	for element in elements {
		if element.id == id { return element }
		if element.children.len > 0 {
			found := failure_test_element(element.children, id) or { continue }
			return found
		}
	}
	return error('missing failure-state element: ' + id)
}

fn test_remote_failed_startup_has_persistent_failure_and_recovery_actions() ! {
	mut app := &Workshop{}
	profile := host.RemoteProfile{id: 'ab'.repeat(12), server_id: 'server', name: 'Test', ssh_host: 'fixture', token: 'not-rendered'}
	app.remote_profiles = [profile]
	app.select_remote_profile(profile)
	app.remote_connected_form = app.remote_form()
	for reported_ready in [false, true] {
		app.remote_snapshot = host.RemoteSnapshot{profile_id: profile.id, connected: true,
			config_status: host.ConfigStatus{state: .effective},
			instance: host.RemoteInstance{ready: reported_ready, manual_restart: true, operation: host.RemoteOperation{state: 'failed', error: 'executor_warmup_failed'}},
			message: '执行器初始化失败。请修复配置、发布后重试。'}
		rows := remote_instance_summary(app, 700, 0)
		ui2.validate_element_tree(ui2.screen(workbench_paper, rows))!
		assert failure_test_element(rows, 'remote_state_summary_title')!.text == '重启失败 · 需修复配置'
		assert failure_test_element(rows, 'remote_state_summary')!.box.border_color == workbench_danger
		assert failure_test_element(rows, 'remote_open_caption')!.text == '打开 Admin UI 修复配置'
		assert failure_test_element(rows, 'remote_restart_caption')!.text == '修复后重试重启'
		assert runtime_test_enabled(rows, 'remote_open')! && runtime_test_enabled(rows, 'remote_restart')!
	}
	app.remote_snapshot = host.RemoteSnapshot{profile_id: profile.id, connected: true, config_status: host.ConfigStatus{state: .effective}, instance: host.RemoteInstance{ready: true, manual_restart: true, operation: host.RemoteOperation{state: 'completed'}}}
	assert failure_test_element(remote_instance_summary(app, 700, 0), 'remote_state_summary_title')!.text == '已连接 · 业务就绪'
}

fn test_remote_runtime_selection_is_explicit_and_does_not_rebind_instances() ! {
	mut app := unsafe { workshop }
	old_state := app.server_snapshot
	defer { app.server_snapshot = old_state; app.server_runtime_selection = '' }
	app.server_busy = false
	app.server_snapshot = host.ServerSnapshot{server: app.server_form(), server_id: app.remote_id, connected: true, version: '0.1.0', runtimes: [host.RemoteRuntime{id: 'legacy', version: '0.1.0'}, host.RemoteRuntime{id: 'sha256-' + 'ab'.repeat(32), version: '0.1.1'}]}
	app.server_runtime_selection = ''
	assert app.selected_server_runtime() == ''
	app.handle_server_event('server_runtime_choice_legacy')
	assert app.selected_server_runtime() == 'legacy'
	app.server_worker = host.ServerWorker{}
	app.server_command(.create, '')
	command := <-app.server_worker.commands
	assert command.runtime_id == 'legacy'
	app.server_busy = false
	app.server_runtime_selection = 'missing'
	assert app.selected_server_runtime() == ''
	for width in [360.0, 700.0] { ui2.validate_element_tree(ui2.screen(workbench_paper, runtime_remote_view(app, width)))! }
}

fn test_runtime_upgrade_controls_and_recovery_states() ! {
 mut app := unsafe { workshop }
 previous := app.server_snapshot
 defer { app.server_snapshot = previous; app.server_upgrade_project = ''; app.server_runtime_selection = '' }
 app.server_busy = false
 app.remote_id = 'ab'.repeat(12)
 app.runtime_server_id = app.remote_id
 app.remote_name = 'fixture'
 app.remote_host = 'fixture'
 project := host.RemoteProfile{id:'cd'.repeat(12), server_id:app.remote_id, name:'app', runtime_id:'legacy', config_path:'/fixture/instances/app/vhttpd.toml'}
 target := 'sha256-' + 'ab'.repeat(32)
 app.server_snapshot = host.ServerSnapshot{server:app.server_form(),server_id:app.remote_id,connected:true,root:'/fixture',version:'0.1.0',runtimes:[host.RemoteRuntime{id:'legacy',version:'0.1.0'},host.RemoteRuntime{id:target,version:'0.2.0'}],projects:[project]}
 app.server_upgrade_project = project.id
 app.server_runtime_selection = 'legacy'
 assert !app.can_upgrade_selected_project()
 app.server_runtime_selection = target
 assert app.can_upgrade_selected_project()
 operation := host.RemoteRuntimeUpgrade{id:'ef'.repeat(12),config_path:project.config_path,phase:'starting'}
 app.server_snapshot = host.ServerSnapshot{...app.server_snapshot,upgrades:[operation]}
 assert !app.can_upgrade_selected_project()
 assert host.upgrade_phase_title(operation).contains('检查生效')
 for phase in ['completed','rolled_back','rollback_failed'] {
  status := host.RemoteRuntimeUpgrade{...operation,phase:phase,error:if phase == 'rolled_back' { 'new_process_exited' } else { '' }}
  app.server_snapshot = host.ServerSnapshot{...app.server_snapshot,upgrades:[status]}
  for width in [360.0,700.0] { ui2.validate_element_tree(ui2.screen(workbench_paper,runtime_remote_view(app,width)))! }
 }
 assert host.upgrade_phase_title(host.RemoteRuntimeUpgrade{phase:'rolled_back'}).contains('原版本已恢复')
 assert host.upgrade_phase_title(host.RemoteRuntimeUpgrade{phase:'rollback_failed'}).contains('需要处理')
}

fn test_runtime_binding_refresh_does_not_require_ssh_reauthentication() {
 before := host.RemoteProfile{id:'ab'.repeat(12),server_id:'cd'.repeat(12),ssh_host:'fixture',token:'fixture-only',runtime_id:'legacy',runtime_path:'/fixture/runtime/vhttpd'}
 after := host.RemoteProfile{...before,runtime_id:'sha256-' + 'ab'.repeat(32),runtime_path:'/fixture/runtimes/new/vhttpd'}
 assert same_remote_connection(before,after)
 assert !same_remote_connection(before,host.RemoteProfile{...after,token:'changed'})
 assert !same_remote_connection(before,host.RemoteProfile{...after,admin_port:2020})
}
