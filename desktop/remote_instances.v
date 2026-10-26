module main

import host
import ui2

fn (app &Workshop) remote_form() host.RemoteProfile {
	mut config_path := ''
	for profile in app.remote_profiles { if profile.id == app.remote_id { config_path = profile.config_path; break } }
	mut binding := host.RemoteProfile{}
	for profile in app.remote_profiles { if profile.id == app.remote_id { binding = profile; break } }
	return host.RemoteProfile{ runtime_id: binding.runtime_id, runtime_path: binding.runtime_path, config_path: config_path, id: app.remote_id, server_id: app.remote_server_id, name: app.remote_name.trim_space(), ssh_host: app.remote_host.trim_space(), ssh_user: app.remote_user.trim_space(), ssh_port: app.remote_port.int(), admin_port: app.remote_admin_port.int(), identity_file: app.remote_identity, auth_method: app.remote_auth, token: app.remote_token }
}

fn (mut app Workshop) send_remote(action host.RemoteAction) {
	next := app.remote_sequence + 1
	command := host.RemoteCommand{action: action, profile: app.remote_form(), control_path: app.remote_control_path(),
		password: if action == .connect { app.remote_password } else { '' }, host_key_id: app.remote_snapshot.host_key.id, sequence: next}
	select {
		app.remote_worker.commands <- command {
			app.remote_sequence = next
			if action == .connect { app.remote_edit_connection = false; app.remote_connected_form = app.remote_form(); app.remote_password = '' }
			if action == .disconnect {
				app.remote_password = ''
				if app.remote_snapshot.host_key.id != '' {
					app.remote_message = '已取消主机指纹确认，未保存信任记录。'
					app.remote_snapshot = host.RemoteSnapshot{ ...app.remote_snapshot, host_key: host.RemoteHostKey{}, busy: false }
				}
			}
			if action == .confirm_host_key {
				app.remote_snapshot = host.RemoteSnapshot{ ...app.remote_snapshot, host_key: host.RemoteHostKey{}, message: '已确认主机指纹，正在连接…' }
			}
			if action in [.connect, .restart] {
				app.remote_snapshot = host.RemoteSnapshot{
					...app.remote_snapshot
					profile_id: app.remote_id
					host_key: host.RemoteHostKey{}
					host_key_changed: false
					busy:       true
					message:    if action == .connect {
						'正在连接远端实例…'
					} else {
						'正在校验项目并提交重启…'
					}
				}
			}
		}
		else {
			app.remote_message = '操作正在处理，请稍候。'
		}
	}
}

fn (mut app Workshop) handle_remote_event(event string) bool {
	if event == 'remote_instances' {
		app.show_remote = true
		app.show_shared_relays = false
		app.show_runtime = false
		return true
	}
	if !event.starts_with('remote_') { return false }
	if event == 'remote_edit' && !app.remote_snapshot.busy { app.remote_edit_connection = true; return true }
	if event == 'remote_close' {
		app.show_remote = app.environment_id != ''
		if app.environment_id != '' { app.remote_id = '' }
		app.remote_password = ''
		return true
	}
	if event == 'remote_disconnect' {
		app.send_remote(.disconnect)
		return true
	}
	if event == 'remote_trust_host' {
		if app.remote_snapshot.profile_id == app.remote_id && same_remote_connection(app.remote_form(), app.remote_connected_form) && !app.remote_snapshot.host_key_changed {
			app.remote_message = ''
			app.send_remote(.confirm_host_key)
		}
		return true
	}
	if app.remote_snapshot.busy { return true }
	match event {
		'remote_new' {
			app.remote_server_id = ''
			app.remote_id = host.new_remote_id() or { return true }
			app.remote_name = ''
			app.remote_host = ''
			app.remote_user = ''
			app.remote_port = ''
			app.remote_admin_port = '2018'
			app.remote_token = ''
			app.remote_identity = ''
			app.remote_auth = 'key'
			app.remote_password = ''
			app.remote_edit_connection = true
			for server in app.remote_servers { if server.id == app.environment_id {
				app.remote_server_id = server.id
				app.remote_host = server.ssh_host
				app.remote_user = server.ssh_user
				app.remote_port = if server.ssh_port == 0 { '' } else { server.ssh_port.str() }
				app.remote_identity = server.identity_file
				app.remote_auth = server.auth_method
			} }
			app.remote_message = '填写已运行实例的 SSH 和 Admin 连接。Token 保存在本机权限保护的文件中。'
		}
		'remote_name' { app.remote_name = ui2.text(event) }
		'remote_host' { app.remote_host = ui2.text(event) }
		'remote_user' { app.remote_user = ui2.text(event) }
		'remote_port' { app.remote_port = ui2.text(event) }
		'remote_admin_port' { app.remote_admin_port = ui2.text(event) }
		'remote_token' { app.remote_token = ui2.text(event) }
		'remote_password' { app.remote_password = ui2.text(event) }
		'remote_auth_key', 'remote_auth_password' {
			method := if event == 'remote_auth_password' { 'password' } else { 'key' }
			if app.remote_auth != method {
				app.remote_auth = method
				app.remote_password = ''
			}
		}
		'remote_identity' {
			files := ui2.open_file_dialog(title: '选择 SSH 私钥（仅保留路径）')
			if files.len > 0 { app.remote_identity = files[0] }
		}
		'remote_identity_clear' { app.remote_identity = '' }
		'remote_save', 'remote_connect' {
			if (app.remote_port != '' && !app.remote_port.bytes().all(it.is_digit())) || !app.remote_admin_port.bytes().all(it.is_digit()) {
				app.remote_message = '端口请填写数字。'
				return true
			}
			profile := app.remote_form()
			profile.validate() or {
				app.remote_message = err.msg()
				return true
			}
			if event == 'remote_connect' && profile.auth_method == 'password' && app.remote_control_path() == '' {
				host.validate_ssh_password(app.remote_password) or { app.remote_message = err.msg(); return true }
			}
			items := app.remote_profiles.filter(it.id != profile.id)
			mut saved := items.clone()
			saved << profile
			host.save_remote_profiles(saved) or {
				app.remote_message = '保存失败，请检查本机连接目录的写入权限。'
				return true
			}
			app.remote_profiles = saved
			app.set_environment(profile_environment(profile))
			app.remote_message = '连接已保存。'
			if event == 'remote_connect' {
				app.remote_message = ''
				app.connect_remote_project(profile)
			}
		}
		'remote_delete' {
			if !ui2.confirm('移除远端连接', '只移除本机连接记录，远端实例和配置继续保留。') {
				return true
			}
			host.save_remote_profiles(app.remote_profiles.filter(it.id != app.remote_id)) or {
				app.remote_message = '移除失败。'
				return true
			}
			app.remote_profiles = app.remote_profiles.filter(it.id != app.remote_id)
			if app.remote_snapshot.profile_id == app.remote_id { app.send_remote(.disconnect) }
			app.remote_id = ''
			app.remote_password = ''
			app.remote_message = '连接记录已移除。'
		}
		'remote_open' {
			app.remote_message = ''
			if app.remote_snapshot.connected && app.remote_snapshot.profile_id == app.remote_id { app.send_remote(.open_admin) } else { app.remote_auto_open = true; app.connect_remote_project(app.remote_form()) }
		}
		'remote_check' {
			app.remote_message = ''
			app.send_remote(.check)
		}
		'remote_restart' {
			if app.remote_upgrade_running() { app.remote_message = '远端正在切换运行包或恢复原版本，请等待升级结果。'; return true }
			if ui2.confirm('重启远端 vhttpd', '将先校验整个项目，再重启远端手工实例。重启期间连接会短暂中断，随后自动检查所有 include 配置是否生效。') {
				app.remote_message = ''
				app.send_remote(.restart)
			}
		}
		else {
			if event.starts_with('remote_select_') {
				id := event.all_after('remote_select_')
				for p in app.remote_profiles {
					if p.id == id {
						app.select_remote_profile(p)
					}
				}
			}
		}
	}
	return true
}

fn remote_instances_view(app &Workshop, width f64) []ui2.Element {
	mut rows := [
		label('remote_heading', if app.environment_id == '' { '远端实例' } else { app.environment_name() + ' · 项目' }, 0, 28, width - 120, 26, workbench_ink),
		label('remote_description', 'SSH 连接已运行的 vhttpd，配置在 Admin UI 编辑，重启和生效检查在这里完成。', 0, 68, width, 12, workbench_muted),
		button('remote_close', '项目概览', width - 100, 25, 100, false, true),
		button(if app.environment_id == '' { 'server_back' } else { 'remote_new' }, if app.environment_id == '' { '服务器' } else { '导入已有实例' }, 145, 103, 130, false, !app.remote_snapshot.busy),
		button(if app.environment_id == '' { 'remote_new' } else { 'remote_create_project' }, if app.environment_id == '' { '+ 添加实例' } else { '+ 新建项目' }, 0, 103, 130, true, !app.remote_snapshot.busy),
	]
	mut y := 153.0
	for p in app.remote_profiles {
		if app.environment_id != '' { continue }
		rows << sidebar_button('remote_select_${p.id}', p.name + ' · ' + p.ssh_host + if p.id == app.remote_snapshot.profile_id {
			if app.remote_snapshot.busy {
				' · 正在处理'
			} else if app.remote_snapshot.connected {
				' · 已连接'
			} else {
				''
			}
		} else {
			''
		}, ui2.rect(0, y, width, 34), false, p.id == app.remote_id, !app.remote_snapshot.busy, .left)
		y += 42
	}
	if app.remote_id == '' {
		rows << label('remote_empty', '从左侧选择远端项目；新建项目会使用当前环境的运行包，导入可登记已运行的实例。', 0, y + 12, width, 14, workbench_muted)
		return rows
	}
	if app.remote_upgrade_running() {
		for profile in app.remote_profiles { if profile.id == app.remote_id {
			for upgrade in app.server_snapshot.upgrades { if upgrade.config_path == profile.config_path && !upgrade.finished() {
				rows << state_notice('remote_upgrade_progress', host.upgrade_phase_title(upgrade), '业务正在停机切换或恢复。SSH 认证没有变化，无需重复输入密码；结果保存在远端。', ui2.rect(0, y, width, 124), 'info')
				rows << button('runtime', '查看运行包升级状态', 0, y + 140, 190, true, true)
				return rows
			} }
		} }
	}
	if app.remote_snapshot.connected && app.remote_snapshot.profile_id == app.remote_id && same_remote_connection(app.remote_form(), app.remote_connected_form) && !app.remote_edit_connection {
		rows << remote_instance_summary(app, width, y)
		return rows
	}
	challenge := app.remote_snapshot.host_key
	if app.remote_snapshot.profile_id == app.remote_id && challenge.id != '' {
		rows << state_notice('remote_host_key_notice', '首次连接：请核对 SSH 主机指纹',
			'主机：${app.remote_host}' + if app.remote_port != '' { ':${app.remote_port}' } else { '' } + '\n密钥类型：${challenge.algorithm}\n指纹：${challenge.fingerprint}',
			ui2.rect(0, y, width, 124), 'warning')
		rows << ui2.label('remote_host_key_help', '请通过服务器管理员或可信渠道核对指纹。信任后由系统 SSH 记住此主机，再继续登录。', ui2.rect(0, y + 136, width, 48), ui2.TextStyle{size: 12, color: workbench_muted, lines: 2})
		rows << button('remote_trust_host', '信任此主机并连接', 0, y + 190, 190, true, true)
		rows << button('remote_disconnect', '取消连接', 204, y + 190, 110, false, true)
		return rows
	}
	if app.remote_snapshot.profile_id == app.remote_id && app.remote_snapshot.host_key_changed {
		rows << state_notice('remote_host_key_changed', '主机指纹已变化 · 连接已阻止',
			'当前指纹：${challenge.fingerprint}\n已保存的信任记录不会自动覆盖。\n请通过可信渠道核对服务器是否重装或更换密钥。', ui2.rect(0, y, width, 124), 'danger')
		y += 140
	}
	editable := !app.remote_snapshot.busy
	half := (width - 16) / 2
	rows << label('remote_name_label', '实例名称', 0, y, half, 12, workbench_muted)
	rows << label('remote_host_label', 'SSH 主机 / Host 别名', half + 16, y, half, 12, workbench_muted)
	rows << input('remote_name', app.remote_name, '例如：开发服务器', 0, y + 23, half, editable)
	rows << input('remote_host', app.remote_host, '例如：dev-server', half + 16, y + 23, half, editable)
	y += 72
	rows << label('remote_user_label', 'SSH 用户（留空沿用 SSH 配置）', 0, y, half, 12, workbench_muted)
	rows << label('remote_port_label', 'SSH 端口（留空沿用 SSH 配置）', half + 16, y, half, 12, workbench_muted)
	rows << input('remote_user', app.remote_user, '默认用户', 0, y + 23, half, editable)
	rows << input('remote_port', app.remote_port, '默认端口', half + 16, y + 23, half, editable)
	y += 72
	rows << label('remote_auth_label', 'SSH 认证方式', 0, y, width, 12, workbench_muted)
	rows << choice_button('remote_auth_key', '密钥 / SSH 配置', 0, y + 23, 170, app.remote_auth == 'key', editable)
	rows << choice_button('remote_auth_password', '密码登录', 182, y + 23, 130, app.remote_auth == 'password', editable)
	y += 72
	if app.remote_auth == 'password' {
		rows << ui2.Element{ ...input('remote_password', app.remote_password, 'SSH 登录密码（仅本次连接使用）', 0, y, width, editable), secure: true }
		y += 43
		rows << label('remote_password_hint', '密码不保存到磁盘；连接提交后清空，重新连接时需再次输入。', 0, y, width, 11, workbench_muted)
		y += 33
	} else {
	rows << button('remote_identity', if app.remote_identity == '' {
		'选择私钥（可选）…'
	} else {
		'更换 SSH 私钥…'
	}, 0, y, 155, false, editable)
	rows << button('remote_identity_clear', '使用 SSH 配置', 167, y, 145, false, editable)
	y += 43
	rows << label('remote_identity_hint', if app.remote_identity == '' {
		'使用系统 SSH 配置、密钥和 ssh-agent；首次连接可直接在工作台核对主机指纹。'
	} else {
		app.remote_identity
	}, 0, y, width, 11, workbench_muted)
	y += 33
	}
	rows << label('remote_admin_label', '远端 Admin 端口（通过 SSH 访问远端 127.0.0.1）', 0, y, width, 12, workbench_muted)
	rows << input('remote_admin_port', app.remote_admin_port, '2018', 0, y + 23, 130, editable)
	rows << ui2.Element{ ...input('remote_token', app.remote_token, '远端 Admin Token', 146, y + 23, width - 146, editable), secure: true }
	y += 74
	rows << button('remote_save', '保存', 0, y, 90, false, editable)
	rows << button('remote_connect', '保存并连接', 102, y, 130, true, editable)
	rows << button('remote_delete', '移除连接', width - 105, y, 105, false, editable)
	y += 54
	active := app.remote_snapshot.profile_id == app.remote_id
	same_connection := same_remote_connection(app.remote_form(), app.remote_connected_form)
	connected := active && app.remote_snapshot.connected && same_connection
	instance := app.remote_snapshot.instance
	message := if active && app.remote_snapshot.connected && !same_connection {
		'连接信息已修改，请点击“保存并连接”后继续。'
	} else if app.remote_message != '' {
		app.remote_message
	} else if active {
		app.remote_snapshot.message
	} else {
		'连接后查看运行版本和配置状态。'
	}
	rows << label('remote_status', message, 0, y, width, 13, workbench_ink)
	y += 38
	if instance.version == '' && app.remote_form().config_path != '' {
		rows << ui2.label('remote_discovered_source', '远端配置：' + app.remote_form().config_path, ui2.rect(0, y, width, 44), ui2.TextStyle{size: 11, color: workbench_muted, lines: 2})
		y += 50
	}
	if active && instance.version != '' {
		rows << label('remote_version', 'vhttpd ${instance.version} · ${instance.platform} · ' + if instance.ready {
			'业务就绪'
		} else {
			'尚未就绪'
		}, 0, y, width, 13, workbench_ink)
		rows << label('remote_config_source', instance.config_path, 0, y + 27, width, 11, workbench_muted)
		y += 65
	}
	rows << button('remote_open', if connected { '打开 Admin UI' } else { '连接并打开 Admin UI' }, 0, y, 175, true, (connected || app.remote_control_path() != '') && !app.remote_snapshot.busy && !app.server_busy)
	rows << button('remote_restart', '重启并检查生效', 0, y + 49, 170, false, connected && !app.remote_snapshot.busy && instance.manual_restart)
	rows << button('remote_check', '检查', 182, y + 49, 65, false, connected && !app.remote_snapshot.busy)
	rows << button('remote_disconnect', '断开', width - 70, y, 70, false, active)
	y += 98
	rows << label('remote_restart_hint', if connected && !instance.manual_restart {
		'此实例未启用手工重启；远端需使用 --manual-restart 启动。'
	} else {
		'发布后回到这里重启；断开连接或退出工作台不会停止远端实例。'
	}, 0, y, width, 11, workbench_muted)
	return rows
}

fn (app &Workshop) remote_control_path() string {
	if app.remote_server_id == '' || app.server_snapshot.server_id != app.remote_server_id || !app.server_snapshot.connected { return '' }
	for server in app.remote_servers {
		if server.id == app.remote_server_id && server == app.server_snapshot.server && server.ssh_host == app.remote_host.trim_space() && server.ssh_user == app.remote_user.trim_space() && server.ssh_port == app.remote_port.int() { return app.server_snapshot.control_path }
	}
	return ''
}

fn remote_instance_summary(app &Workshop, width f64, y f64) []ui2.Element {
	state := app.remote_snapshot
	mut rows := [label('remote_connected_name', app.remote_name, 0, y, width, 22, workbench_ink),
		label('remote_connected_host', app.remote_host + ' · Admin ' + app.remote_admin_port, 0, y + 37, width, 12, workbench_muted),
		label('remote_version', 'vhttpd ' + state.instance.version + ' · ' + state.instance.platform, 0, y + 70, width, 13, workbench_ink),
		state_notice('remote_state_summary', if state.restarting { '正在重启并检查生效' } else if state.instance.startup_failed() { '重启失败 · 需修复配置' } else if !state.instance.ready { '业务尚未就绪' } else if state.config_status.pending { '配置待重启生效' } else { '已连接 · 业务就绪' }, if app.remote_message != '' { app.remote_message } else { state.message }, ui2.rect(0, y + 112, width, 100), if state.restarting { 'info' } else if state.instance.startup_failed() { 'danger' } else if state.config_status.pending || !state.instance.ready { 'warning' } else { 'good' }),
		button('remote_open', if state.instance.startup_failed() { '打开 Admin UI 修复配置' } else { '打开远端 Admin UI ↗' }, 0, y + 234, 180, true, !state.busy),
		button('remote_restart', if state.instance.startup_failed() { '修复后重试重启' } else { '重启并检查生效' }, 192, y + 234, 175, false, !state.busy && state.instance.manual_restart && !app.remote_upgrade_running()),
		button('remote_check', '检查生效', 0, y + 283, 110, false, !state.busy),
		button('remote_edit', '编辑连接…', 122, y + 283, 125, false, !state.busy),
		button('remote_disconnect', '断开', width - 75, y + 283, 75, false, true),
		ui2.label('remote_config_source', state.instance.config_path, ui2.rect(0, y + 341, width, 52), ui2.TextStyle{size: 11, color: workbench_muted, lines: 3}),
		label('remote_restart_hint', '配置在 Admin UI 编辑；发布后回到这里重启和检查生效。', 0, y + 408, width, 11, workbench_muted),
		remote_access_notice(app, width, y + 445)]
	return rows
}

fn remote_access_notice(app &Workshop, width f64, y f64) ui2.Element {
	bg, ink := state_colors('info')
	height := if width < 420 { 244.0 } else { 208.0 }
	url := if app.remote_snapshot.admin_url == '' { '由工作台分配本机入口' } else { app.remote_snapshot.admin_url }
	mut binding := host.RemoteProfile{}
	for profile in app.remote_profiles { if profile.id == app.remote_id { binding = profile; break } }
	mut runtime := if binding.runtime_id == 'legacy' { '原有运行包' } else if binding.runtime_id != '' { binding.runtime_id[..if binding.runtime_id.len > 19 { 19 } else { binding.runtime_id.len }] } else { '外部启动，未绑定工作台运行包' }
	if app.server_snapshot.server_id == binding.server_id {
		for installed in app.server_snapshot.runtimes { if installed.id == binding.runtime_id { runtime = installed.label(); break } }
	}
	detail := '运行包：' + runtime + if binding.runtime_path != '' { '\n进程路径：' + binding.runtime_path } else { '' } + '\n目标：'  + app.remote_host + ' 的 127.0.0.1:' + app.remote_admin_port + '\n浏览器入口：' + url + '\n本机地址仅是 SSH 代理入口，配置修改仍发生在远端实例。'
	return ui2.view('remote_access', ui2.rect(0, y, width, height), ui2.BoxStyle{bg: bg, radius: 8, border_color: ink, border_left: 3}, [
		ui2.label('remote_access_title', '通过 SSH 隧道访问远端 Admin', ui2.rect(16, 11, width - 32, 24), ui2.TextStyle{size: 13, bold: true, color: ink}),
		ui2.label('remote_access_detail', detail, ui2.rect(16, 39, width - 32, height - 48), ui2.TextStyle{size: 12, color: workbench_muted, lines: 8}),
	])
}

// Reuse one authenticated server session for discovery and all project tunnels.
// A stale cached token is replaced before connecting to the Admin API.
fn (mut app Workshop) connect_remote_project(profile host.RemoteProfile) {
	if profile.server_id != '' && app.remote_control_path() == '' {
		for server in app.remote_servers {
			if server.id != profile.server_id { continue }
			next := app.server_sequence + 1
			command := host.ServerCommand{sequence: next, action: .connect, server: server, password: app.remote_password}
			select {
				app.server_worker.commands <- command {
					app.server_sequence = next
					app.server_busy = true
					app.remote_pending_connect = profile.id
					app.remote_snapshot = host.RemoteSnapshot{profile_id: profile.id, busy: true, message: '正在通过 SSH 同步远端项目…'}
					app.remote_password = ''
					app.remote_message = '正在连接服务器并同步远端项目，再连接 Admin UI…'
				}
				else { app.remote_message = '服务器操作正在处理，请稍候。' }
			}
			return
		}
	}
	app.send_remote(.connect)
}

fn (app &Workshop) remote_upgrade_running() bool {
 for profile in app.remote_profiles {
  if profile.id == app.remote_id && profile.server_id == app.server_snapshot.server_id { return app.server_snapshot.upgrades.any(it.config_path == profile.config_path && !it.finished()) }
 }
 return false
}

fn same_remote_connection(a host.RemoteProfile, b host.RemoteProfile) bool {
 return host.RemoteProfile{...a,runtime_id:'',runtime_path:''} == host.RemoteProfile{...b,runtime_id:'',runtime_path:''}
}
