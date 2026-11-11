module main

import host
import ui2

fn (app &Workshop) server_form() host.RemoteServer {
	return host.RemoteServer{id: app.remote_id, name: app.remote_name.trim_space(), ssh_host: app.remote_host.trim_space(), ssh_user: app.remote_user.trim_space(),
		ssh_port: app.remote_port.int(), identity_file: app.remote_identity, auth_method: app.remote_auth}
}

fn (mut app Workshop) select_server(server host.RemoteServer) {
	if app.remote_servers.any(it.id == server.id) { app.set_environment(server.id) }
	if app.remote_id != server.id { app.server_runtime_selection = ''; app.server_upgrade_project = '' }
	app.remote_id = server.id
	app.remote_name = server.name
	app.remote_host = server.ssh_host
	app.remote_user = server.ssh_user
	app.remote_port = if server.ssh_port == 0 { '' } else { server.ssh_port.str() }
	app.remote_auth = server.auth_method
	app.remote_identity = server.identity_file
	app.remote_password = ''
	app.remote_message = ''
}

fn (mut app Workshop) server_command(action host.ServerAction, archive string) {
	next := app.server_sequence + 1
	command := host.ServerCommand{initialize_environment: action == .install && app.server_snapshot.projects.len == 0, sequence: next, action: action, server: app.server_form(), password: if action == .connect { app.remote_password } else { '' },
		host_key_id: app.server_snapshot.host_key.id, archive: archive, release_tag: if action == .install { app.runtime_selected_tag } else { '' }, name: app.server_instance_name.trim_space(),
		project_id: app.server_upgrade_project, runtime_id: app.selected_server_runtime(), template: host.project_templates()[app.server_template].id, web_port: app.server_web_port.int(), admin_port: app.server_admin_port.int()}
	select {
		app.server_worker.commands <- command {
			app.server_sequence = next
			if action in [.install, .create, .upgrade] {
				app.runtime_operation_sequence = next
				app.runtime_operation_server = app.runtime_server_id
				app.runtime_form_error = ''
				if action == .upgrade { app.runtime_upgrade_before = app.server_snapshot.upgrades.map(it.id) }
			}
			if action == .connect { app.remote_password = '' }
			if action in [.connect, .install, .create, .upgrade, .inspect] { app.server_busy = true }
			app.remote_message = ''
		}
		else { app.remote_message = '操作正在处理中，请稍候。' }
	}
}

fn (mut app Workshop) poll_server() {
	select {
		status := <-app.server_worker.snapshots {
			if status.sequence < app.server_sequence { return }
			discovered := status.discovery_revision != app.server_discovery_revision
			completed := !status.busy && (app.server_busy || app.server_snapshot.busy || (status.connected && !app.server_snapshot.connected))
			if completed || discovered { app.reload_remote_profiles() }
			if discovered { app.server_discovery_revision = status.discovery_revision }
			if status.mcp_registered_host.id != '' && !app.remote_servers.any(it.id == status.mcp_registered_host.id) { app.remote_servers = host.load_remote_servers() or { app.remote_servers } }
			if status.mcp_relay_catalog_serial != app.development_relay_catalog_serial {
				app.development_relay_catalog_serial = status.mcp_relay_catalog_serial
				app.shared_relays = host.load_shared_relays() or { app.shared_relays }
			}
			app.server_snapshot = status
			if app.shared_catalog_pending && !status.busy {
				app.shared_catalog_pending = false
				if app.shared_scope == app.environment_id {app.shared_message = status.message}
				if !status.error && app.shared_scope == app.environment_id && app.show_shared_relays {app.select_initial_shared_relay()}
			}
			// The worker emits completion after each blocking operation.
			if !status.busy { app.server_busy = false }
			if app.remote_pending_connect != '' && status.host_key.id != '' && !status.error {
				// First use on another computer must expose the server's trust UI.
				app.select_server(status.server)
				app.show_remote = true
				app.show_servers = true
				app.show_runtime = false
			}
			if !status.busy && app.remote_pending_connect != '' {
				pending := app.remote_pending_connect
				app.remote_pending_connect = ''
				if status.connected && !status.error {
					for profile in app.remote_profiles {
						if profile.id == pending { app.select_remote_profile(profile); app.send_remote(.connect); break }
					}
				} else { app.remote_auto_open = false; app.remote_snapshot = host.RemoteSnapshot{profile_id: pending, message: status.message}; app.remote_message = status.message }
			} else if discovered && app.show_remote && !app.show_servers && !app.show_runtime && !app.remote_snapshot.connected && !app.remote_snapshot.busy {
				for profile in app.remote_profiles { if profile.id == app.remote_id { app.select_remote_profile(profile); break } }
			}

			if status.created.id != '' && status.created.id != app.server_created_id {
				app.server_created_id = status.created.id
				app.reload_remote_profiles()
				p := status.created
				app.set_environment(profile_environment(p))
				app.remote_id = p.id
				app.remote_server_id = p.server_id
				app.remote_name = p.name
				app.remote_host = p.ssh_host
				app.remote_user = p.ssh_user
				app.remote_port = p.ssh_port.str()
				app.remote_admin_port = p.admin_port.str()
				app.remote_auth = p.auth_method
				app.remote_identity = p.identity_file
				app.remote_token = p.token
				app.remote_connected_form = p
				app.remote_auto_open = true
				app.show_runtime = false
				app.show_remote = true
				app.show_servers = false
				app.remote_sequence++
				app.remote_worker.commands <- host.RemoteCommand{action: .connect, profile: p, control_path: status.control_path, sequence: app.remote_sequence}
				app.server_command(.inspect, '')
				app.remote_message = ''
			}
		}
		else {}
	}
}

fn (app &Workshop) selected_server_runtime() string {
	if app.server_snapshot.runtimes.any(it.id == app.server_runtime_selection) { return app.server_runtime_selection }
	for project in app.managed_runtime_projects() {
		if project.id == app.selected_upgrade_project() && app.server_snapshot.runtimes.any(it.id == project.runtime_id) { return project.runtime_id }
	}
	if app.server_snapshot.runtimes.len == 1 { return app.server_snapshot.runtimes[0].id }
	return ''
}

fn (app &Workshop) can_upgrade_selected_project() bool {
 if app.server_snapshot.server_id != app.runtime_server_id || app.server_snapshot.server != app.server_form() || app.server_busy || app.server_snapshot.busy || !app.server_snapshot.connected || app.server_snapshot.upgrades.any(!it.finished()) || app.deployment_running() { return false }
 selected := app.managed_runtime_projects().filter(it.id == app.selected_upgrade_project())
 return selected.len == 1 && selected[0].runtime_id != '' && app.selected_server_runtime() != '' && selected[0].runtime_id != app.selected_server_runtime() && selected[0].config_path == app.server_snapshot.root + '/instances/' + selected[0].name + '/vhttpd.toml'
}

fn (mut app Workshop) handle_server_event(event string) bool {
 if event == 'server_upgrade_environment' {
  if !app.server_busy && !app.server_snapshot.busy {
   for project in app.managed_runtime_projects() { if project.name == ui2.text(event) {app.server_upgrade_project=project.id;app.server_runtime_selection='';app.runtime_history_open=false;app.runtime_operation_sequence=0;app.runtime_form_error='';break} }
  }
  return true
 }
 if event == 'runtime_history_toggle' { app.runtime_history_open = !app.runtime_history_open; return true }
 if event == 'runtime_create_open' { app.runtime_create_open = true; app.runtime_form_error=''; return true }
 if event == 'runtime_create_back' { app.runtime_create_open = false; app.runtime_form_error=''; app.runtime_operation_sequence=0; return true }
 if event.starts_with('server_upgrade_project_') {
  if !app.server_busy && !app.server_snapshot.busy { app.server_upgrade_project = event.all_after('server_upgrade_project_') }
  return true
 }
 if event == 'server_upgrade' {
  if !app.can_upgrade_selected_project() { return true }
  project := app.managed_runtime_projects().filter(it.id == app.selected_upgrade_project())[0]
  target := app.server_snapshot.runtimes.filter(it.id == app.selected_server_runtime())[0]
  previous := app.server_snapshot.runtimes.filter(it.id == project.runtime_id)
  previous_label := if previous.len == 1 { previous[0].label() } else { '当前运行包' }
  if ui_confirm('切换运行环境版本', project.name + ' 将从 ' + previous_label + ' 切换到 ' + target.label() + '。该环境内全部应用会短暂停机；先校验完整配置，失败时自动恢复原运行包。') { app.server_upgrade_project=project.id; app.server_command(.upgrade, '') }
  return true
 }

	if event.starts_with('server_runtime_choice_') {
		id := event.all_after('server_runtime_choice_')
		if !app.server_busy && !app.server_snapshot.busy && !app.server_snapshot.upgrades.any(!it.finished()) && app.server_snapshot.runtimes.any(it.id == id) { app.server_runtime_selection = id; app.runtime_operation_sequence=0; app.runtime_form_error='' }
		return true
	}

	if event in ['server_home', 'server_back'] {
		app.reload_remote_profiles()
		was_servers := app.show_servers
		app.show_remote = true
		app.show_servers = true
		app.show_runtime = false
		app.show_shared_relays = false
		if !app.server_busy && !app.server_snapshot.busy && (!was_servers || app.remote_id == '') {
			mut selected := false
			for server in app.remote_servers { if server.id == app.environment_id { app.select_server(server); selected = true; break } }
			if !selected { if app.remote_servers.len > 0 { app.select_server(app.remote_servers[0]) } else { app.select_server(host.RemoteServer{}) } }
		}
		return true
	}
	if event.starts_with('runtime_target_') {
		if !app.can_switch_environment() { return true }
		app.set_environment(event.all_after('runtime_target_'))
		for server in app.remote_servers { if server.id == app.environment_id { app.select_server(server) } }
		app.show_runtime_downloads = false
		app.runtime_selected_tag = ''
		return true
	}
	if event == 'server_instances' {
		if !app.server_busy && !app.server_snapshot.busy { app.show_servers = false; app.remote_id = ''; app.remote_server_id = ''; app.remote_password = '' }
		return true
	}
	if !event.starts_with('server_') { return false }
	if event == 'server_disconnect' { app.server_command(.disconnect, ''); app.remote_password = ''; return true }
	if event == 'server_cancel' { select { app.server_worker.job.cancel <- true {} else {} }; return true }
	if event == 'server_trust' { app.server_command(.trust, ''); return true }
	if app.server_busy || app.server_snapshot.busy { return true }
	match event {
		'server_new' { app.select_server(host.RemoteServer{id: host.new_remote_id() or { return true }}) }
		'server_name' { app.remote_name = ui2.text(event) }
		'server_host' { app.remote_host = ui2.text(event) }
		'server_user' { app.remote_user = ui2.text(event) }
		'server_port' { app.remote_port = ui2.text(event) }
		'server_password' { app.remote_password = ui2.text(event) }
		'server_key' { app.remote_auth = 'key'; app.remote_password = '' }
		'server_password_mode' { app.remote_auth = 'password'; app.remote_password = '' }
		'server_identity' { files := ui2.open_file_dialog(title: ui_text('选择 SSH 私钥')); if files.len > 0 { app.remote_identity = files[0] } }
		'server_identity_clear' { app.remote_identity = '' }
		'server_save', 'server_connect' {
			if app.remote_port != '' && !app.remote_port.bytes().all(it.is_digit()) { app.remote_message = 'SSH 端口请填写数字。'; return true }
			s := app.server_form()
			s.validate() or { app.remote_message = err.msg(); return true }
			if event == 'server_connect' && s.auth_method == 'password' { host.validate_ssh_password(app.remote_password) or { app.remote_message = err.msg(); return true } }
			mut items := app.remote_servers.filter(it.id != s.id)
			items << s
			host.save_remote_servers(items) or { app.remote_message = err.msg(); return true }
			app.remote_servers = items
			app.set_environment(s.id)
			app.remote_message = '服务器已保存。连接后可在运行环境中安装运行包并创建实例。'
			if event == 'server_connect' { app.server_command(.connect, '') }
		}
		'server_delete' {
			if !ui_confirm('移除服务器', '仅移除本机服务器记录；远端运行包、实例和已保存的实例连接继续保留。') { return true }
			items := app.remote_servers.filter(it.id != app.remote_id)
			host.save_remote_servers(items) or { app.remote_message = err.msg(); return true }
			if app.server_snapshot.server_id == app.remote_id { app.server_command(.disconnect, '') }
			app.remote_servers = items
			if !app.environment_choices().any(it.id == app.environment_id) { app.set_environment('') }
			app.select_server(host.RemoteServer{})
		}
		'server_runtime' {
			if !app.server_snapshot.connected || app.server_form() != app.server_snapshot.server {
				app.remote_message = '请先保存并连接这台服务器，再管理运行环境。'
				return true
			}
			app.set_environment(app.remote_id)
			app.show_runtime_downloads = false
			app.show_remote = false
			app.show_runtime = true
		}
		'server_go_connect' {
			for s in app.remote_servers { if s.id == app.runtime_server_id { app.select_server(s) } }
			app.show_runtime = false
			app.show_remote = true
			app.show_servers = true
		}
		'server_refresh' { app.reload_remote_profiles(); app.server_command(.inspect, '') }
		'server_install' { app.open_runtime_downloads() }
		'server_package' {
			files := ui2.open_file_dialog(title: ui_text('选择官方 CI 的 vhttpd-linux-*.tar.gz（旁边需有同名 .sha256）'))
			if files.len > 0 { app.server_command(.install, files[0]) }
		}
		'server_instance_name' { app.server_instance_name = ui2.text(event) }
		'server_web_port' { app.server_web_port = ui2.text(event) }
		'server_admin_port' { app.server_admin_port = ui2.text(event) }
		'server_template_environment' { app.server_template = 2 }
		'server_template_http' { app.server_template = 0 }
		'server_template_api' { app.server_template = 1 }
		'server_create' {
			if app.server_busy || app.server_snapshot.busy { return true }
			if !app.server_web_port.bytes().all(it.is_digit()) || !app.server_admin_port.bytes().all(it.is_digit()) { app.runtime_form_error = '监听和 Admin 端口请填写数字。'; return true }
			app.server_command(.create, '')
		}
		else {
			if event.starts_with('server_select_') {
				for s in app.remote_servers { if s.id == event.all_after('server_select_') { app.select_server(s) } }
			}
		}
	}
	return true
}

fn remote_servers_view(app &Workshop, width f64) []ui2.Element {
	list_width := if width >= 620 { 174.0 } else { 144.0 }
	detail_x := list_width + 24
	mut rows := [label('server_title', '远端服务器', 0, 26, width - 120, 24, workbench_colors.ink),
		label('server_intro', '连接服务器 → 安装运行包 → 创建运行环境', 0, 62, width, 12, workbench_colors.muted),
		button('remote_close', '返回运行环境', width - 100, 26, 100, false, true)]
	busy := app.server_busy || app.server_snapshot.busy
	mut selector := [button('server_new', '+ 添加服务器', 10, 10, list_width - 20, false, !busy)]
	mut items := []ui2.Element{}
	mut y := 0.0
	for server in app.remote_servers {
		items << sidebar_button('server_select_${server.id}', server.name, ui2.rect(0, y, list_width - 20, 36), false, server.id == app.remote_id, !busy, .left)
		y += 42
	}
	selector << ui2.scroll('server_list', ui2.rect(10, 58, list_width - 20, 335), workbench_colors.sidebar, items)
	selector << button('server_instances', '已运行实例…', 10, 410, list_width - 20, false, !busy)
	rows << ui2.view('server_selector', ui2.rect(0, 106, list_width, 460), ui2.BoxStyle{bg: workbench_colors.sidebar, radius: 8}, selector)
	rows << ui2.view('server_detail', ui2.rect(detail_x, 106, width - detail_x, elements_height(server_detail_view(app, width - detail_x))), ui2.BoxStyle{transparent: true}, server_detail_view(app, width - detail_x))
	return rows
}

fn server_detail_view(app &Workshop, width f64) []ui2.Element {
	if app.remote_id == '' {
		return [label('server_empty_title', '先添加一台服务器', 0, 18, width, 20, workbench_colors.ink),
			ui2.label('server_empty_help', '只需 SSH 地址和登录方式。\n服务器尚未安装 vhttpd 也可以添加，\n这里不需要 Admin Token。', ui2.rect(0, 60, width, 90), ui2.TextStyle{size: 13, color: workbench_colors.muted, lines: 4})]
	}
	state := app.server_snapshot
	active := state.server_id == app.remote_id
	busy := app.server_busy || state.busy
	connected := active && state.connected && app.server_form() == state.server
	mut rows := [label('server_detail_title', if app.remote_servers.any(it.id == app.remote_id) { app.remote_name } else { ui_text('添加服务器') }, 0, 0, width, 20, workbench_colors.ink)]
	if active && state.host_key.id != '' {
		rows << state_notice('server_fingerprint', '首次连接 · 核对主机指纹', app.remote_host + '\n' + state.host_key.algorithm + '\n' + state.host_key.fingerprint, ui2.rect(0, 44, width, 145), 'warning')
		rows << ui2.label('server_fingerprint_help', '通过管理员或可信渠道核对后再信任。取消不会保存信任记录。', ui2.rect(0, 204, width, 54), ui2.TextStyle{size: 12, color: workbench_colors.muted, lines: 3})
		rows << button('server_trust', '信任并继续', 0, 274, 135, true, true)
		rows << button('server_disconnect', '取消', 147, 274, 75, false, true)
		return rows
	}
	message := if app.remote_message != '' { app.remote_message } else if active { state.message } else { '填写连接信息后，保存并连接。' }
	notice_height := if active && state.error { 100.0 } else { 76.0 }
	rows << state_notice('server_state', if active && state.host_key_changed { '主机指纹变化 · 已阻止连接' } else if busy { '正在连接…' } else if connected { '已连接 · 下一步准备运行环境' } else if active && state.error { '连接未完成' } else { 'SSH 连接' }, message, ui2.rect(0, 38, width, notice_height), if active && state.host_key_changed { 'danger' } else if active && state.error { 'warning' } else if connected { 'good' } else { 'info' })
	mut y := notice_height + 55
	rows << ui2.label('server_connection_section', '连接地址', ui2.rect(0, y, width, 23), ui2.TextStyle{size: 13, bold: true, color: workbench_colors.ink})
	y += 33
	half := (width - 14) / 2
	rows << label('server_name_label', '显示名称', 0, y, half, 11, workbench_colors.muted)
	rows << label('server_host_label', 'SSH 主机', half + 14, y, half, 11, workbench_colors.muted)
	rows << input('server_name', app.remote_name, '例如：测试环境', 0, y + 20, half, !busy)
	rows << input('server_host', app.remote_host, 'IP 或 Host 别名', half + 14, y + 20, half, !busy)
	y += 73
	rows << label('server_user_label', '用户（可选）', 0, y, half, 11, workbench_colors.muted)
	rows << label('server_port_label', '端口（可选）', half + 14, y, half, 11, workbench_colors.muted)
	rows << input('server_user', app.remote_user, '沿用 SSH 配置', 0, y + 20, half, !busy)
	rows << input('server_port', app.remote_port, '沿用 SSH 配置', half + 14, y + 20, half, !busy)
	y += 83
	rows << ui2.label('server_auth_heading', '登录方式', ui2.rect(0, y, width, 23), ui2.TextStyle{size: 13, bold: true, color: workbench_colors.ink})
	y += 31
	rows << choice_button('server_key', '密钥 / SSH 配置', 0, y, half, app.remote_auth == 'key', !busy)
	rows << choice_button('server_password_mode', '密码', half + 14, y, half, app.remote_auth == 'password', !busy)
	y += 49
	if app.remote_auth == 'password' {
		rows << ui2.Element{...input('server_password', app.remote_password, 'SSH 登录密码', 0, y, width, !busy), secure: true}
		rows << label('server_password_help', '仅本次连接使用，不保存到磁盘。', 0, y + 44, width, 11, workbench_colors.muted)
	} else {
		rows << button('server_identity', '选择私钥…', 0, y, half, false, !busy)
		rows << button('server_identity_clear', '使用 SSH 配置', half + 14, y, half, false, !busy)
		rows << label('server_identity_path', if app.remote_identity == '' { ui_text('使用系统密钥和 ssh-agent。') } else { app.remote_identity }, 0, y + 44, width, 11, workbench_colors.muted)
	}
	y += 86
	rows << button('server_save', '保存', 0, y, 75, false, !busy)
	rows << button(if connected { 'server_runtime' } else { 'server_connect' }, if connected { '管理运行环境 →' } else { '保存并连接' }, width - 165, y, 165, true, !busy)
	y += 48
	rows << button('server_disconnect', '断开连接', 0, y, 105, false, active && (state.connected || state.busy))
	rows << button('server_delete', '移除…', width - 78, y, 78, false, !busy && app.remote_servers.any(it.id == app.remote_id))
	rows << label('server_keyboard_help', 'Tab 切换 · Shift+Tab 返回 · Return 连接', 0, y + 46, width, 10, workbench_colors.muted)
	return rows
}

fn runtime_settings_view(app &Workshop, width f64) []ui2.Element {
	list_width := if width >= 620 { 174.0 } else { 144.0 }
	x := list_width + 24
	mut selector := [label('runtime_target_label', '目标主机', 10, 12, list_width - 20, 11, workbench_colors.muted),
		sidebar_button('runtime_target_', host.local_environment_name(), ui2.rect(10, 40, list_width - 20, 34), false, app.runtime_server_id == '', app.can_switch_environment(), .left)]
	mut y := 86.0
	for server in app.remote_servers {
		selector << sidebar_button('runtime_target_${server.id}', server.name, ui2.rect(10, y, list_width - 20, 34), false, app.runtime_server_id == server.id, app.can_switch_environment(), .left)
		y += 42
	}
	body := if app.show_runtime_downloads { runtime_downloads_view(app, width - x) } else if app.runtime_server_id == '' { runtime_local_view(app, width - x) } else { runtime_remote_view(app, width - x) }
	return [label('runtime_page_heading', '运行包', 0, 26, width - 120, 24, workbench_colors.ink),
		label('runtime_page_help', '运行包提供 vhttpd 程序与依赖；运行环境保存配置、应用和数据。', 0, 62, width, 12, workbench_colors.muted),
		button('runtime_close', '返回运行环境', width - 100, 26, 100, false, true),
		ui2.view('runtime_selector', ui2.rect(0, 106, list_width, if y > 200 { y + 16 } else { 200.0 }), ui2.BoxStyle{bg: workbench_colors.sidebar, radius: 8}, selector),
		ui2.view('runtime_detail', ui2.rect(x, 106, width - x, elements_height(body)), ui2.BoxStyle{transparent: true}, body)]
}

fn elements_height(elements []ui2.Element) f64 {
	mut height := 0.0
	for element in elements { if element.frame.y + element.frame.height > height { height = element.frame.y + element.frame.height } }
	return height + 24
}
