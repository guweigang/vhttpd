module main

import host
import ui2

fn fixture_menu_item(menus []ui2.Menu, action string) ui2.MenuItem {
	for menu in menus { if item := menu_find(menu.items, 'menu:' + action) { return item } }
	panic('missing menu action: ' + action)
}

fn test_menu_structure_empty_and_local_lifecycle_states() ! {
	mut app := Workshop{}
	root := ui2.screen(workbench_paper, [])
	menus := app.workbench_menus(root)
	ui2.validate_menus(menus)!
	assert menus[0].title == '项目'
	assert menus[1].title == '编辑'
	assert menus[2].title == '运行'
	assert fixture_menu_item(menus, 'new').enabled
	assert fixture_menu_item(menus, 'new').shortcut == 'cmd+n'
	for action in ['start', 'stop', 'restart', 'admin', 'folder', 'config_diff', 'history_open'] {
		assert !fixture_menu_item(menus, action).enabled
	}
	app.projects = [host.Project{name: 'A', config_path: '/tmp/a.toml'}, host.Project{name: 'B', config_path: '/tmp/b.toml'}]
	app.snapshot = host.Snapshot{phase: .running, pid: 42}
	app.config_statuses['/tmp/a.toml'] = host.ConfigStatus{pending: true}
	running := app.workbench_menus(root)
	assert !fixture_menu_item(running, 'start').enabled
	assert fixture_menu_item(running, 'stop').enabled
	assert fixture_menu_item(running, 'restart').enabled
	assert fixture_menu_item(running, 'admin').title.ends_with(' · A')
	assert fixture_menu_item(running, 'project_0').checked
	assert !fixture_menu_item(running, 'project_1').checked
	assert !fixture_menu_item(running, 'import').enabled
	card := config_status_view(&app, 0, 0, 708)
	assert fixture_menu_item(running, 'config_diff').enabled == menu_button_enabled(card, 'config_diff')
	app.snapshot = host.Snapshot{phase: .stopping, pid: 42}
	stopping := app.workbench_menus(root)
	for action in ['start', 'stop', 'restart', 'admin'] { assert !fixture_menu_item(stopping, action).enabled }
	app.snapshot = host.Snapshot{phase: .failed, pid: 42, can_force: true}
	failed := app.workbench_menus(root)
	assert fixture_menu_item(failed, 'force').enabled
	app.snapshot = host.Snapshot{phase: .stopped}
	app.selected = 1
	stopped := app.workbench_menus(root)
	assert fixture_menu_item(stopped, 'start').enabled
	assert fixture_menu_item(stopped, 'project_1').checked
	assert !fixture_menu_item(stopped, 'project_0').checked
	assert fixture_menu_item(stopped, 'start').title.ends_with(' · B')
	app.new_project = true
	assert !fixture_menu_item(app.workbench_menus(root), 'start').enabled
}

fn test_edit_menu_selection_readonly_and_password_guards() {
	field := input('fixture', 'sample', '', 0, 0, 200, true)
	rows := edit_menu_rows_for(field, false)
	assert !rows[0].enabled && !rows[1].enabled
	assert rows[2].enabled && rows[3].enabled
	selected := edit_menu_rows_for(field, true)
	assert selected.all(it.enabled)
	secret := edit_menu_rows_for(ui2.Element{...field, secure: true}, true)
	assert !secret[0].enabled && !secret[1].enabled
	assert secret[2].enabled && secret[3].enabled
	readonly := edit_menu_rows_for(ui2.Element{...field, readonly: true}, true)
	assert !readonly[0].enabled && readonly[1].enabled && !readonly[2].enabled && readonly[3].enabled
	empty := edit_menu_rows_for(none, false)
	assert empty.all(!it.enabled)
}

fn test_environment_project_menu_is_scoped_and_busy_gated() ! {
	server_id := 'a'.repeat(24)
	profile_id := 'b'.repeat(24)
	app := Workshop{environment_id: server_id, remote_id: profile_id,
		projects: [host.Project{name: 'local-only'}],
		remote_servers: [host.RemoteServer{id: server_id, name: 'Server', ssh_host: 'fixture'}],
		remote_profiles: [host.RemoteProfile{id: profile_id, name: 'remote-only', server_id: server_id}]}
	menus := app.workbench_menus(ui2.screen(workbench_paper, []))
	ui2.validate_menus(menus)!
	assert fixture_menu_item(menus, 'remote_select_' + profile_id).checked
	assert fixture_menu_item(menus, 'environment:' + server_id).checked
	assert !fixture_menu_item(menus, 'environment:').checked
	assert !fixture_menu_item(menus, 'folder').enabled
	for menu in menus { assert menu_find(menu.items, 'menu:project_0') == none }
	busy := Workshop{...app, server_busy: true}
	busy_menus := busy.workbench_menus(ui2.screen(workbench_paper, []))
	assert !fixture_menu_item(busy_menus, 'remote_select_' + profile_id).enabled
	assert !fixture_menu_item(busy_menus, 'environment:').enabled
	assert !fixture_menu_item(busy_menus, 'remote_restart').enabled
}
