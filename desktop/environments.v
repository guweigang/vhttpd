module main

import host
import ui2

struct EnvironmentChoice {
	id    string
	title string
}

fn profile_environment(p host.RemoteProfile) string {
	return if p.server_id != '' { p.server_id } else { 'profile:' + p.id }
}

// Registry writes precede remote creation, including attempts that later fail.
// Refresh on navigation and server-operation completion rather than keeping a
// startup-only snapshot that can hide an existing/retryable project.
fn (mut app Workshop) reload_remote_profiles() {
	profiles := host.load_remote_profiles() or {
		app.remote_profiles_error = '远端项目登记读取失败，请保留 remote-instances.json 并检查文件权限与内容。'
		return
	}
	app.remote_profiles = profiles
	app.remote_profiles_error = ''
}

fn (app &Workshop) environment_choices() []EnvironmentChoice {
	mut choices := [EnvironmentChoice{ title: '本机 Mac' }]
	for server in app.remote_servers {
		mut title := '远端 · ' + server.name
		for choices.any(it.title == title) { title += ' · ' + server.ssh_host }
		choices << EnvironmentChoice{ id: server.id, title: title }
	}
	for p in app.remote_profiles {
		if p.server_id != '' && app.remote_servers.any(it.id == p.server_id) { continue }
		if choices.any(it.id == profile_environment(p)) { continue }
		mut title := 'SSH · ' + p.name
		for choices.any(it.title == title) { title += ' · ' + p.ssh_host }
		choices << EnvironmentChoice{ id: profile_environment(p), title: title }
	}
	return choices
}

fn (app &Workshop) environment_name() string {
	for choice in app.environment_choices() {
		if choice.id == app.environment_id { return choice.title }
	}
	return '远端环境'
}

fn (app &Workshop) environment_profiles() []host.RemoteProfile {
	if app.environment_id == '' { return []host.RemoteProfile{} }
	return app.remote_profiles.filter(profile_environment(it) == app.environment_id)
}

fn (app &Workshop) can_switch_environment() bool {
	return !app.creating && !app.new_project && !app.runtime_busy && !app.server_busy && !app.server_snapshot.busy && !app.remote_snapshot.busy && app.snapshot.phase !in [
		.starting,
		.stopping,
	]
}

fn (app &Workshop) environment_menu_items() []ui2.DropdownMenuItem {
	return app.environment_choices().map(ui2.dropdown_menu_radio('environment_choice_' + it.id, it.title, it.id == app.environment_id))
}

fn (app &Workshop) environment_selector() ui2.Element {
	return painted_button(ui2.dropdown_menu_toggle_action('environment_menu'), app.environment_name() + ' ▾', ui2.rect(16, 82, 180, 34), ui2.BoxStyle{bg: workbench_paper, radius: 6}, workbench_ink, app.can_switch_environment(), .left, 10)
}

fn (mut app Workshop) apply_environment_menu(step ui2.DropdownMenuStep) {
	app.environment_menu = step.state
	if step.chosen { app.open_environment_projects(step.item.id.all_after('environment_choice_')) }
}

fn (app &Workshop) environment_version_label() string {
	if app.environment_id != '' {
		if app.remote_snapshot.connected && app.remote_profiles.any(it.id == app.remote_snapshot.profile_id && profile_environment(it) == app.environment_id) {
			return '远端 vhttpd ' + app.remote_snapshot.instance.version
		}
		if app.server_snapshot.connected && app.server_snapshot.server_id == app.environment_id {
			return if app.server_snapshot.version != '' {
				'远端 vhttpd ' + app.server_snapshot.version
			} else {
				'远端 · 尚未安装运行包'
			}
		}
		return '远端 · 未连接'
	}
	return if app.runtime_info.ready {
		'本机 vhttpd ' + app.runtime_info.version
	} else if app.runtime_busy {
		'正在检查运行包…'
	} else {
		'本机运行包不可用'
	}
}

fn (mut app Workshop) set_environment(id string) {
	app.environment_id = id
	app.runtime_server_id = if id.starts_with('profile:') { '' } else { id }
	app.show_runtime_downloads = false
	app.runtime_selected_tag = ''
}

fn (mut app Workshop) select_remote_profile(p host.RemoteProfile) {
	app.set_environment(profile_environment(p))
	app.remote_edit_connection = false
	app.remote_id = p.id
	app.remote_server_id = p.server_id
	app.remote_name = p.name
	app.remote_host = p.ssh_host
	app.remote_user = p.ssh_user
	app.remote_port = if p.ssh_port == 0 { '' } else { p.ssh_port.str() }
	app.remote_admin_port = p.admin_port.str()
	app.remote_token = p.token
	app.remote_identity = p.identity_file
	app.remote_auth = p.auth_method
	for server in app.remote_servers {
		if server.id == p.server_id {
			app.remote_host = server.ssh_host
			app.remote_user = server.ssh_user
			app.remote_port = if server.ssh_port == 0 { '' } else { server.ssh_port.str() }
			app.remote_identity = server.identity_file
			app.remote_auth = server.auth_method
		}
	}
	app.remote_password = ''
	app.remote_message = ''
	app.show_runtime = false
	app.show_shared_relays = false
	app.show_remote = true
	app.show_servers = false
}

fn (mut app Workshop) open_environment_projects(id string) {
	app.set_environment(id)
	app.show_runtime = false
	app.show_shared_relays = false
	app.show_remote = id != ''
	app.show_servers = false
	if id != '' {
		app.remote_id = ''
		profiles := app.environment_profiles()
		if profiles.len > 0 { app.select_remote_profile(profiles[0]) }
	}
}

fn (mut app Workshop) open_environment_runtime() {
	app.show_shared_relays = false
	app.show_runtime_downloads = false
	if app.environment_id == '' {
		app.show_remote = false
		app.show_runtime = true
		return
	}
	for s in app.remote_servers {
		if s.id == app.environment_id {
			app.select_server(s)
			app.show_remote = false
			app.show_runtime = true
			return
		}
	}
	app.show_remote = true
	app.show_servers = true
	app.show_runtime = false
	app.remote_message = '请先添加并连接服务器，再安装运行包或创建远端项目。'
}

fn (mut app Workshop) handle_environment_event(event string) bool {
	if step := ui2.dropdown_menu_update('environment_menu', app.environment_menu_items(), app.environment_menu, event) {
		if !app.can_switch_environment() { return true }
		if step.chosen { app.reload_remote_profiles() }
		app.apply_environment_menu(step)
		return true
	}

	if event == 'runtime' {
		app.open_environment_runtime()
		return true
	}
	if event == 'runtime_close' {
		app.runtime_resume_start = false
		app.open_environment_projects(app.environment_id)
		return true
	}
	if app.environment_id != '' && event in ['start', 'stop', 'force', 'restart', 'apply_restart',
		'admin', 'business', 'folder', 'edit_config', 'edit_source', 'history_open'] {
		app.remote_message = '当前是远端环境。请使用远端项目的 Admin UI、重启和生效检查；远端目录不在本机。'
		return true
	}
	if app.environment_id != '' && event in ['new', 'empty_new', 'remote_create_project'] {
		app.open_environment_runtime()
		return true
	}
	if app.environment_id != '' && event in ['import', 'empty_import'] {
		app.show_remote = true
		app.show_servers = false
		app.show_runtime = false
		app.handle_remote_event('remote_new')
		return true
	}
	return false
}
