module main

import host
import ui2

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
	project := host.Project{name: 'app', config_path: '/tmp/app/vhttpd.toml', workdir: '/tmp/app'}
	app.projects = [project]
	app.selected = 0
	for phase in [host.Phase.stopped, .starting, .running, .stopping, .failed] {
		app.snapshot = host.Snapshot{phase: phase}
		for state in [host.ConfigState.unknown, .checking, .effective, .pending, .unavailable] {
			app.config_statuses[project.config_path] = host.ConfigStatus{state: state, pending: state == .pending, recovery_available: true}
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
	app.snapshot = host.Snapshot{phase: .running, pid: 1}
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
			_, _, tone := config_status_copy(host.Snapshot{phase: phase}, host.ConfigStatus{state: state, pending: state == .pending})
			assert (tone == 'good') == (phase == .running && state == .effective)
		}
	}
	// A failed check can retain earlier differences, but cannot confirm them.
	title, _, tone := config_status_copy(host.Snapshot{phase: .running}, host.ConfigStatus{state: .unavailable, pending: true})
	assert title == '生效状态未确认'
	assert tone == 'warning'
}

fn test_restart_stop_result_does_not_cancel_new_instance_browser_login() {
	mut app := unsafe { workshop }
	app.projects = [host.Project{name: 'restart', config_path: '/tmp/restart/vhttpd.toml', workdir: '/tmp/restart'}]
	app.selected = 0
	app.worker = host.Worker{}
	app.snapshot = host.Snapshot{phase: .stopped, message: '实例已停止。'}
	app.restart_after = true
	app.request_open = false
	app.continue_lifecycle(app.snapshot)
	assert app.snapshot.phase == .starting
	assert app.request_open
	start := <-app.worker.commands
	assert start.action == .start
	app.continue_lifecycle(host.Snapshot{phase: .starting, pid: 10})
	assert app.request_open
	app.continue_lifecycle(host.Snapshot{phase: .running, pid: 10})
	assert !app.request_open
	open := <-app.worker.commands
	assert open.action == .open_admin
}
