module main

import host
import ui2

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
