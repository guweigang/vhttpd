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
	assert menus[0].title == '文件'
	assert menus[1].title == '编辑'
	assert menus[2].title == '运行环境'
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
	assert fixture_menu_item(running, 'admin').title == '打开 Admin UI'
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
	assert fixture_menu_item(stopped, 'start').title == '启动运行环境'
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

fn test_menu_shortcuts_share_the_current_enabled_state() {
	root := ui2.screen(workbench_paper, [])
	mut app := Workshop{}
	menus := app.workbench_menus(root)
	for key, action in {'cmd+n': 'new', 'cmd+o': 'import', 'cmd+comma': 'runtime'} {
		item := workbench_menu_key_command(menus, key) or { panic('missing shortcut') }
		assert item.id == 'menu:' + action
		assert item.enabled
	}
	app.new_project = true
	blocked := workbench_menu_key_command(app.workbench_menus(root), 'cmd+n') or { panic('disabled shortcut disappeared') }
	assert !blocked.enabled
	assert workbench_menu_key_command(menus, 'cmd+shift+n') == none
	assert workbench_menu_key_command(menus, 'n') == none
	assert workbench_menu_key_command(menus, 'cmd+r') == none
	$if macos { assert workbench_menu_key_command(menus, 'ctrl+n') == none }
	$if !macos {
		item := workbench_menu_key_command(menus, 'ctrl+n') or { panic('Control shortcut missing') }
		assert item.id == 'menu:new'
	}
	for row in edit_menu_rows_for(ui2.Element{...input('secret', 'fixture', '', 0, 0, 200, true), secure: true}, true) {
		if row.id in ['menu:edit_cut', 'menu:edit_copy'] { assert !row.enabled }
		assert row.shortcut != ''
	}
}

// A language change may replace labels, never commands or their placement.
fn menu_identity_rows(rows []ui2.MenuItem) []ui2.MenuItem {
	return rows.map(ui2.MenuItem{...it, title: '', items: menu_identity_rows(it.items)})
}

fn menu_identity(menus []ui2.Menu) []ui2.Menu {
	return menus.map(ui2.Menu{...it, title: '', items: menu_identity_rows(it.items)})
}

fn assert_menu_labels_translated(rows []ui2.MenuItem) {
	for row in rows {
		if row.id.starts_with('menu:project_') || row.id.starts_with('menu:remote_select_')
			|| row.id.starts_with('menu:environment:') || row.id == 'menu:language:zh-CN'
			|| row.title == 'Language / 语言' { continue }
		assert !row.title.runes().any(it >= 0x4e00 && it <= 0x9fff), row.title
		assert_menu_labels_translated(row.items)
	}
}

fn test_bilingual_menu_structure_state_and_shortcuts_are_identical() ! {
	previous := workbench_language
	previous_preference := workbench_language_preference
	defer { workbench_language = previous; workbench_language_preference = previous_preference }
	server_id := 'a'.repeat(24)
	profile_id := 'b'.repeat(24)
	base := Workshop{projects: [host.Project{name: '运行环境', config_path: '/tmp/menu.toml'}]}
	remote := Workshop{environment_id: server_id, remote_id: profile_id,
		remote_servers: [host.RemoteServer{id: server_id, name: '文件', ssh_host: 'fixture'}],
		remote_profiles: [host.RemoteProfile{id: profile_id, name: '管理', server_id: server_id}]}
	fixtures := [Workshop{}, base,
		Workshop{...base, snapshot: host.Snapshot{phase: .running, pid: 42}},
		Workshop{...base, snapshot: host.Snapshot{phase: .starting}},
		Workshop{...base, snapshot: host.Snapshot{phase: .failed, can_force: true, pid: 42}},
		Workshop{...base, new_project: true},
		Workshop{...base, show_runtime: true},
		Workshop{...base, workspace_page: .applications},
		remote, Workshop{...remote, server_busy: true}]
	for preference in ['auto', 'zh-CN', 'en'] {
		workbench_language_preference = preference
		for app in fixtures {
			root := ui2.screen(workbench_paper, [])
			workbench_language = 'zh-CN'
			chinese := app.workbench_menus(root)
			workbench_language = 'en'
			english := app.workbench_menus(root)
			ui2.validate_menus(chinese)!
			ui2.validate_menus(english)!
			assert menu_identity(chinese) == menu_identity(english)
			for menu in english { assert_menu_labels_translated(menu.items) }
			assert fixture_menu_item(english, 'language:' + preference).checked
			assert english.map(it.title) == chinese.map(ui_text(it.title))
		}
	}
}

fn test_menu_groups_and_workspace_navigation_follow_concepts() {
	previous := workbench_language
	defer { workbench_language = previous }
	workbench_language = 'zh-CN'
	mut app := Workshop{projects: [host.Project{name: 'bodytest'}],
		snapshot: host.Snapshot{phase: .running, pid: 42}, show_runtime: true, show_development: true, show_component_install: true,
		workspace_application: 'wechat', workspace_log_application: 'wechat', workspace_log_source: 'stdout'}
	menus := app.workbench_menus(ui2.screen(workbench_paper, []))
	assert menus[0].items.any(it.id == 'menu:new')
	assert menus[2].items.any(it.id == 'menu:start')
	assert menus[4].items.any(it.id == 'menu:runtime')
	assert menus[4].items.any(it.id == 'menu:mcp_settings')
	assert !fixture_menu_item(menus, 'overview').checked
	assert menus[3].items.filter(it.title == 'Language / 语言').len == 1
	before := app.snapshot
	for i, action in ['overview', 'applications', 'relay', 'configuration', 'logs'] {
		app.menu_workspace_page(action)
		assert int(app.workspace_page) == i
		assert !app.show_runtime && !app.show_development && !app.show_component_install
		current := app.workbench_menus(ui2.screen(workbench_paper, []))
		assert fixture_menu_item(current, action).checked
		assert current[3].items.filter(it.checked).len == 1
		assert app.snapshot == before
		assert app.workspace_application == 'wechat'
	}
	assert app.workspace_log_application == ''
	assert app.workspace_log_source == ''
}
