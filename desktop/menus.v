module main

import host
import ui2

// Menu commands are revalidated on dispatch. The menu's displayed state is
// never authority to start an action after its project/connection has changed.
fn menu_row(action string, title string, enabled bool, shortcut string) ui2.MenuItem {
	return ui2.MenuItem{id: 'menu:' + action, title: title, enabled: enabled, shortcut: shortcut}
}

fn (app &Workshop) can_new_or_import() bool {
	return if app.environment_id != '' { !app.server_busy && !app.remote_snapshot.busy } else {
		!app.new_project && !app.runtime_busy && app.snapshot.pid == 0 && app.snapshot.phase !in [.starting, .stopping]
	}
}

fn (app &Workshop) local_command_enabled(action string) bool {
	if app.creating || app.new_project || app.environment_id != '' || app.projects.len == 0 || app.selected < 0 || app.selected >= app.projects.len { return false }
	s := app.snapshot
	status := app.config_statuses[app.projects[app.selected].config_path] or { host.ConfigStatus{} }
	return match action {
		'start' { s.pid == 0 && s.phase !in [.starting, .stopping] }
		'stop' { (s.pid != 0 || s.phase in [.starting, .stopping]) && !s.can_force && s.phase != .stopping }
		'force' { s.can_force }
		'restart', 'apply_restart', 'check_config', 'admin' { s.phase == .running }
		'config_diff' { status.pending || status.state == .unavailable || status.recovery_available }
		'history_open' { status.recovery_available }
		'folder', 'details', 'overview', 'logs' { !app.new_project }
		'deploy_open' { s.phase !in [.starting, .stopping] }
		else { false }
	}
}

fn menu_button_enabled(element ui2.Element, action string) bool {
	if !element.enabled || element.hidden { return false }
	if (element.kind == .button || element.button_behavior) && (element.id == action || element.action_id == action) { return true }
	for child in element.children { if menu_button_enabled(child, action) { return true } }
	return false
}

fn menu_focused_element(root ui2.Element, id string) ?ui2.Element {
	if root.hidden || !root.enabled { return none }
	if root.id == id && root.kind in [.text_field, .text_area] { return root }
	for child in root.children { if found := menu_focused_element(child, id) { return found } }
	return none
}

fn edit_menu_rows_for(field_opt ?ui2.Element, has_selection bool) []ui2.MenuItem {
	mut writable := false
	mut exportable := false
	mut focused := false
	if field := field_opt {
		focused = true
		writable = !field.readonly
		exportable = !field.secure && has_selection
	}
	return [menu_row('edit_cut', '剪切', writable && exportable, 'cmd+x'),
		menu_row('edit_copy', '复制', exportable, 'cmd+c'),
		menu_row('edit_paste', '粘贴', writable, 'cmd+v'),
		menu_row('edit_all', '全选', focused, 'cmd+a')]
}

fn edit_menu_rows(root ui2.Element) []ui2.MenuItem {
	return edit_menu_rows_for(menu_focused_element(root, ui2.focused_id()), menu_text_has_selection())
}

fn (app &Workshop) workbench_menus(root ui2.Element) []ui2.Menu {
	available := !app.creating
	local := app.environment_id == ''
	mut choices := []ui2.MenuItem{}
	if local {
		for i, project in app.projects {
			choices << ui2.MenuItem{...menu_row('project_${i}', project.name, !app.new_project && available, ''), checked: i == app.selected}
		}
	} else {
		for profile in app.environment_profiles() {
			choices << ui2.MenuItem{...menu_row('remote_select_' + profile.id, profile.name, !app.remote_snapshot.busy && !app.server_busy && available, ''), checked: profile.id == app.remote_id}
		}
	}
	if choices.len == 0 { choices << menu_row('no_projects', '此环境暂无项目', false, '') }
	mut environments := []ui2.MenuItem{}
	for choice in app.environment_choices() {
		environments << ui2.MenuItem{...menu_row('environment:' + choice.id, choice.title, app.can_switch_environment(), ''), checked: choice.id == app.environment_id}
	}
	mut selected := ''
	if local && app.projects.len > 0 && app.selected >= 0 && app.selected < app.projects.len { selected = app.projects[app.selected].name }
	if !local { for profile in app.environment_profiles() { if profile.id == app.remote_id { selected = profile.name } } }
	target := if selected == '' { '' } else { ' · ' + selected }
	remote_controls := if !local && selected != '' { ui2.screen(workbench_paper, remote_instances_view(app, 708)) } else { ui2.screen(workbench_paper, []) }
	can_remote := available && !app.server_busy && !app.remote_snapshot.busy && selected != ''
	mut project_items := [menu_row('new', '新建项目…', available && app.can_new_or_import(), 'cmd+n'),
		menu_row('import', if local { '导入已有项目…' } else { '导入已有实例…' }, available && app.can_new_or_import(), 'cmd+o'),
		ui2.submenu('切换项目', choices), ui2.menu_separator(),
		menu_row('folder', '打开项目目录' + target, app.local_command_enabled('folder'), ''),
		menu_row('deploy_open', '部署到远端…', app.local_command_enabled('deploy_open'), '')]
	$if !macos { project_items << [ui2.menu_separator(), menu_row('quit', '退出工作台', available, 'cmd+q')] }
	stop := if local && app.snapshot.can_force { 'force' } else { 'stop' }
	mut menus := [ui2.Menu{title: '项目', items: project_items}, ui2.Menu{title: '编辑', items: edit_menu_rows(root)},
		ui2.Menu{title: '运行', items: [
			menu_row(if local { 'start' } else { 'remote_start' }, '启动' + target, if local { app.local_command_enabled('start') } else { can_remote && menu_button_enabled(remote_controls, 'remote_start') }, ''),
			menu_row(stop, (if stop == 'force' { '强制停止…' } else { '停止' }) + target, local && app.local_command_enabled(stop), ''),
			menu_row(if local { 'restart' } else { 'remote_restart' }, '重启并检查生效' + target, if local { app.local_command_enabled('restart') } else { can_remote && menu_button_enabled(remote_controls, 'remote_restart') }, ''),
			menu_row(if local { 'check_config' } else { 'remote_check' }, '检查生效' + target, if local { app.local_command_enabled('check_config') } else { can_remote && menu_button_enabled(remote_controls, 'remote_check') }, ''),
			ui2.menu_separator(), menu_row(if local { 'admin' } else { 'remote_open' }, '打开 Admin UI' + target, if local { app.local_command_enabled('admin') } else { can_remote && menu_button_enabled(remote_controls, 'remote_open') }, '')]},
		ui2.Menu{title: '环境', items: [ui2.submenu('切换环境', environments), ui2.menu_separator(),
			menu_row('server_home', '服务器与实例…', available, ''), menu_row('runtime', '管理运行环境…', available, 'cmd+,'), menu_row('shared_relays', '共享 Relay…', available, '')]},
		ui2.Menu{title: '查看', items: [menu_row('overview', '项目总览' + target, available && !app.new_project && selected != '', ''),
			menu_row('logs', '运行日志' + target, app.local_command_enabled('logs'), ''), ui2.menu_separator(),
			menu_row('config_diff', '待生效配置差异' + target, app.local_command_enabled('config_diff'), ''), menu_row('history_open', '已生效版本历史' + target, app.local_command_enabled('history_open'), '')]},
		ui2.Menu{title: '帮助', items: [menu_row('help', '使用说明', true, ''), menu_row('shortcuts', '快捷键说明', true, ''), ui2.menu_separator(), menu_row('about', '关于 vhttpd Workbench', true, '')]}]
	$if macos { menus.insert(menus.len - 1, ui2.Menu{title: '窗口', items: [menu_row('minimize', '最小化', true, 'cmd+m'), menu_row('zoom', '缩放', true, ''), menu_row('fullscreen', '进入 / 退出全屏', true, 'ctrl+cmd+f')]}) }
	return menus
}

fn menu_find(items []ui2.MenuItem, id string) ?ui2.MenuItem {
	for item in items {
		if item.id == id { return item }
		if item.items.len > 0 { if found := menu_find(item.items, id) { return if item.enabled { found } else { ui2.disabled(found) } } }
	}
	return none
}

fn (mut app Workshop) refresh_workbench_menus(root ui2.Element) {
	$if macos { if C.vhttpd_workbench_menu_tracking() != 0 { return } }
	menus := app.workbench_menus(root)
	if menus == app.declared_menus { return }
	app.declared_menus = menus
	ui2.set_menu_bar(menus)
	configure_platform_menus()
}

fn (mut app Workshop) menu_overview() {
	app.new_project = false
	app.show_details = false
	app.show_config_diff = false
	app.show_history = false
	app.show_history_diff = false
	app.show_rollback = false
	app.show_runtime = false
	app.show_deployment = false
	app.show_shared_relays = false
	app.close_auxiliary_project_views()
	app.show_servers = false
	app.show_remote = app.environment_id != ''
	app.remote_edit_connection = false
}

fn handle_workbench_menu(event string) bool {
	if !event.starts_with('menu:') { return false }
	mut app := unsafe { workshop }
	menus := app.workbench_menus(build_window())
	mut allowed := false
	for menu in menus { if item := menu_find(menu.items, event) { allowed = item.enabled; break } }
	if !allowed { return true }
	action := event['menu:'.len..]
	if action.starts_with('edit_') { menu_text_edit(action.all_after('edit_')); ui2.refresh(); return true }
	if action.starts_with('environment:') {
		app.reload_remote_profiles()
		app.open_environment_projects(action.all_after('environment:'))
		ui2.refresh()
		return true
	}
	match action {
		'overview', 'logs' {
			app.menu_overview()
			ui2.refresh()
			if action == 'logs' { ui2.scroll_to_rect('project_overview_page', 0, 620, 1, 200); ui2.focus('logs') }
		}
		'config_diff', 'history_open' { app.menu_overview(); handle_event(action) }
		'help' { ui2.alert('使用说明', '选择本机或远端环境 → 新建或导入项目 → 启动并打开 Admin UI。\n\n配置在 Admin UI 编辑、校验和发布；发布后回到工作台，重启并检查整个项目生效。\n\n远端服务器通过 SSH 连接，密码仅用于本次会话。运行包、共享 Relay 与服务器在“环境”菜单管理。') }
		'shortcuts' { ui2.alert('快捷键说明', '⌘（macOS）/ Ctrl（Windows、Linux）\n\nN：新建项目    O：导入项目    ,：管理运行环境\nX / C / V / A：剪切 / 复制 / 粘贴 / 全选\n\nTab / Shift+Tab：下一个 / 上一个控件\n⌘ / Ctrl+Return：提交当前表单\nEsc：返回或取消（主机指纹不会通过 Return 自动接受）') }
		'about' { ui2.alert('关于 vhttpd Workbench', 'vhttpd Workbench\n基于 V / ui2 的开发工作台\n\n当前环境：' + app.environment_name() + '\n' + app.environment_version_label()) }
		'minimize', 'zoom', 'fullscreen' { menu_window_action(action) }
		else { handle_event(action) }
	}
	return true
}


// The fallback is for native backends which forward a command key to the host
// before consulting the menu. The declaration remains the single key map.
fn menu_key_command(items []ui2.MenuItem, pressed ui2.MenuShortcut) ?ui2.MenuItem {
	for item in items {
		if item.separator { continue }
		if item.items.len > 0 {
			if found := menu_key_command(item.items, pressed) { return if item.enabled { found } else { ui2.disabled(found) } }
		} else if item.shortcut != '' && ui2.menu_shortcut_matches(ui2.parse_menu_shortcut(item.shortcut), pressed) {
			return item
		}
	}
	return none
}

fn workbench_menu_key_command(menus []ui2.Menu, key string) ?ui2.MenuItem {
	pressed := ui2.parse_menu_shortcut(if key == 'cmd+comma' || key == 'ctrl+comma' { key.replace('comma', ',') } else { key })
	if !ui2.menu_shortcut_bindable(pressed) { return none }
	for menu in menus { if item := menu_key_command(menu.items, pressed) { return item } }
	return none
}

fn route_workbench_menu_key(key string) bool {
	app := unsafe { workshop }
	if item := workbench_menu_key_command(app.workbench_menus(build_window()), key) {
		// Disabled keys are consumed too: they must not leak into a text field.
		if item.enabled { handle_workbench_menu(item.id) }
		return true
	}
	return false
}
