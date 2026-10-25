module main

import host
import ui2

fn (app &Workshop) remote_form() host.RemoteProfile {
	return host.RemoteProfile{ id: app.remote_id, server_id: app.remote_server_id, name: app.remote_name.trim_space(), ssh_host: app.remote_host.trim_space(), ssh_user: app.remote_user.trim_space(), ssh_port: app.remote_port.int(), admin_port: app.remote_admin_port.int(), identity_file: app.remote_identity, auth_method: app.remote_auth, token: app.remote_token }
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
		app.show_remote = false
		app.remote_password = ''
		return true
	}
	if event == 'remote_disconnect' {
		app.send_remote(.disconnect)
		return true
	}
	if event == 'remote_trust_host' {
		if app.remote_snapshot.profile_id == app.remote_id && app.remote_form() == app.remote_connected_form && !app.remote_snapshot.host_key_changed {
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
			app.remote_message = '连接已保存。'
			if event == 'remote_connect' {
				app.remote_message = ''
				app.send_remote(.connect)
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
			app.send_remote(.open_admin)
		}
		'remote_check' {
			app.remote_message = ''
			app.send_remote(.check)
		}
		'remote_restart' {
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
					}
				}
			}
		}
	}
	return true
}

fn remote_instances_view(app &Workshop, width f64) []ui2.Element {
	mut rows := [
		label('remote_heading', '远端实例', 0, 28, width, 26, workbench_ink),
		label('remote_description', 'SSH 连接已运行的 vhttpd，配置在 Admin UI 编辑，重启和生效检查在这里完成。', 0, 68, width, 12, workbench_muted),
		button('remote_close', '返回项目', width - 100, 103, 100, false, true),
		button('server_back', '服务器', 145, 103, 95, false, !app.remote_snapshot.busy),
		button('remote_new', '+ 添加实例', 0, 103, 130, true, !app.remote_snapshot.busy),
	]
	mut y := 153.0
	for p in app.remote_profiles {
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
		rows << label('remote_empty', '添加远端实例后，先连接，再打开 Admin UI 发布配置。', 0, y + 12, width, 14, workbench_muted)
		return rows
	}
	if app.remote_snapshot.connected && app.remote_snapshot.profile_id == app.remote_id && app.remote_form() == app.remote_connected_form && !app.remote_edit_connection {
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
	same_connection := app.remote_form() == app.remote_connected_form
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
	if active && instance.version != '' {
		rows << label('remote_version', 'vhttpd ${instance.version} · ${instance.platform} · ' + if instance.ready {
			'业务就绪'
		} else {
			'尚未就绪'
		}, 0, y, width, 13, workbench_ink)
		rows << label('remote_config_source', instance.config_path, 0, y + 27, width, 11, workbench_muted)
		y += 65
	}
	rows << button('remote_open', '打开 Admin UI', 0, y, 145, true, connected && !app.remote_snapshot.busy)
	rows << button('remote_restart', '重启并检查生效', 157, y, 170, false, connected && !app.remote_snapshot.busy && instance.manual_restart)
	rows << button('remote_check', '检查', 339, y, 65, false, connected && !app.remote_snapshot.busy)
	rows << button('remote_disconnect', '断开', width - 70, y, 70, false, active)
	y += 49
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
		state_notice('remote_state_summary', if state.restarting { '正在重启并检查生效' } else if state.config_status.pending { '配置待重启生效' } else if state.instance.ready { '已连接 · 业务就绪' } else { '已连接 · 等待就绪' }, state.message, ui2.rect(0, y + 112, width, 100), if state.config_status.pending { 'warning' } else { 'good' }),
		button('remote_open', '打开 Admin UI ↗', 0, y + 234, 180, true, !state.busy),
		button('remote_restart', '重启并检查生效', 192, y + 234, 175, false, !state.busy && state.instance.manual_restart),
		button('remote_check', '检查生效', 0, y + 283, 110, false, !state.busy),
		button('remote_edit', '编辑连接…', 122, y + 283, 125, false, !state.busy),
		button('remote_disconnect', '断开', width - 75, y + 283, 75, false, true),
		ui2.label('remote_config_source', state.instance.config_path, ui2.rect(0, y + 341, width, 52), ui2.TextStyle{size: 11, color: workbench_muted, lines: 3}),
		label('remote_restart_hint', '配置在 Admin UI 编辑；发布后回到这里重启和检查生效。', 0, y + 408, width, 11, workbench_muted)]
	return rows
}
