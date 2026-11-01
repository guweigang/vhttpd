module main

import host
import ui2

fn (app &Workshop) managed_runtime_projects() []host.RemoteProfile {
	return app.server_snapshot.projects.filter(it.runtime_id != '' && it.config_path == app.server_snapshot.root + '/instances/' + it.name + '/vhttpd.toml')
}

fn (app &Workshop) selected_upgrade_project() string {
	projects := app.managed_runtime_projects()
	if projects.any(it.id == app.server_upgrade_project) { return app.server_upgrade_project }
	if projects.any(it.id == app.remote_snapshot.profile_id) {
		return app.remote_snapshot.profile_id
	}
	if projects.any(it.id == app.remote_id) { return app.remote_id }
	if projects.len == 1 { return projects[0].id }
	return ''
}

fn (app &Workshop) runtime_label(id string) string {
	for runtime in app.server_snapshot.runtimes { if runtime.id == id { return runtime.label() } }
	return if id == '' { '尚未绑定运行包' } else { '版本信息待刷新' }
}

fn runtime_remote_view(app &Workshop, width f64) []ui2.Element {
	state := app.server_snapshot
	active := state.server_id == app.runtime_server_id && state.connected && app.remote_servers.any(it.id == app.runtime_server_id && it == state.server)
	busy := app.server_busy || state.busy || state.upgrades.any(!it.finished()) || app.deployment_running()
	mut rows := [label('server_runtime_title', '远端运行包', 0, 12, width, 22, workbench_ink)]
	if !active {
		rows << state_notice('server_need_connect', '先连接目标服务器', '连接后可查看此主机安装的版本，以及各运行环境正在使用的版本。', ui2.rect(0, 58, width, 104), 'info')
		rows << button('server_go_connect', '连接此服务器', 0, 180, 160, true, !busy)
		return rows
	}
	rows << ui2.label('runtime_relationship', '同一个运行包可供多个运行环境使用。安装版本后，为指定环境确认切换。', ui2.rect(0, 50, width, 46), ui2.TextStyle{ size: 12, color: workbench_muted, lines: 2 })
	rows << button('server_install', '下载运行包…', 0, 108, (width - 12) / 2, true, !busy)
	rows << button('server_package', '从本地安装…', (width + 12) / 2, 108, (width - 12) / 2, false, !busy)
	rows << label('server_install_hint', '安装到主机的版本库；已有运行环境保持当前版本。', 0, 154, width, 11, workbench_muted)
	mut y := 198.0
	projects := app.managed_runtime_projects()
	selected := projects.filter(it.id == app.selected_upgrade_project())
	if !app.runtime_create_open {
		rows << label('runtime_environment_label', '1. 选择运行环境', 0, y, width, 15, workbench_ink)
		y += 30
		if projects.len > 0 {
			name := if selected.len == 1 { selected[0].name } else { '请选择运行环境' }
			rows << ui2.Element{ ...ui2.dropdown('server_upgrade_environment', name, projects.map(it.name), ui2.rect(0, y, width, 36), ui2.BoxStyle{ bg: workbench_sidebar, radius: 6 }, ui2.TextStyle{ size: 14, color: workbench_ink }), enabled: !busy }
			y += 48
			rows << ui2.label('runtime_current_binding', '当前运行包：' + if selected.len == 1 {
				app.runtime_label(selected[0].runtime_id)
			} else {
				'选择环境后查看'
			}, ui2.rect(0, y, width, 42), ui2.TextStyle{ size: 12, color: workbench_muted, lines: 2 })
			y += 58
		} else {
			rows << label('runtime_no_environments', '尚无已绑定的运行环境，可在安装版本后新建。', 0, y, width, 12, workbench_muted)
			y += 40
		}
	} else {
		rows << button('runtime_create_back', '← 返回版本切换', 0, y, 160, false, !busy)
		y += 54
	}
	rows << label('server_runtime_list_heading', if app.runtime_create_open {
		'选择新环境使用的运行包'
	} else {
		'2. 选择已安装运行包'
	}, 0, y, width - 80, 15, workbench_ink)
	rows << button('server_refresh', '刷新', width - 72, y - 6, 72, false, !busy)
	y += 34
	mut packages := []ui2.Element{}
	current_id := if !app.runtime_create_open && selected.len == 1 {
		selected[0].runtime_id
	} else {
		''
	}
	mut runtimes := state.runtimes.filter(it.id == current_id)
	runtimes << state.runtimes.filter(it.id != current_id)
	for i, runtime in runtimes {
		chosen := app.selected_server_runtime() == runtime.id
		current := !app.runtime_create_open && selected.len == 1 && selected[0].runtime_id == runtime.id
		users := state.projects.filter(it.runtime_id == runtime.id).map(it.name)
		meta := if current {
			'此环境正在使用'
		} else if users.len > 0 {
			'使用环境：' + users.join('、')
		} else {
			'尚无运行环境使用'
		}
		packages << ui2.view('runtime_package_row_' + runtime.id, ui2.rect(0, f64(i) * 72, width - 12, 64), ui2.BoxStyle{
			bg:           if chosen {
				workbench_soft_accent
			} else {
				workbench_sidebar
			}
			radius:       6
			border_color: workbench_accent
			border_left:  if chosen { 3.0 } else { 0.0 }
		}, [
			label('runtime_package_name_' + runtime.id, (if chosen { '已选择 · ' } else { '' }) + runtime.label(), 12, 8, width - 38, 13, workbench_ink),
			label('runtime_users_' + runtime.id, meta, 12, 35, width - 38, 11, workbench_muted),
			ui2.Element{
				...ui2.button('server_runtime_choice_' + runtime.id, '', ui2.rect(0, 0, width - 12, 64), ui2.BoxStyle{ transparent: true }, ui2.TextStyle{})
				enabled:             !busy
				accessibility_label: runtime.label() + ' · ' + meta + if chosen {
					' · 已选择'
				} else {
					' · 点击选择'
				}
			},
		])
	}
	list_height := if packages.len == 0 {
		48.0
	} else if packages.len < 4 {
		f64(packages.len) * 72
	} else {
		228.0
	}
	if packages.len == 0 {
		packages << label('runtime_empty_library', '尚未安装运行包，请先下载或从本地安装。', 12, 14, width - 24, 12, workbench_muted)
	}
	rows << ui2.scroll('runtime_package_library', ui2.rect(0, y, width, list_height), workbench_paper, packages)
	y += list_height + 20
	if app.runtime_create_open {
		rows << runtime_create_form(app, width, y)
		y = elements_height(rows)
	} else if selected.len == 1 {
		target := app.selected_server_runtime()
		if target == selected[0].runtime_id {
			rows << ui2.label('runtime_already_current', '当前环境已使用所选版本。点击列表中的其他版本，查看切换预览。', ui2.rect(0, y, width, 48), ui2.TextStyle{ size: 12, color: workbench_muted, lines: 2 })
			y += 62
		} else if target != '' {
			rows << ui2.label('runtime_switch_preview', '切换预览 · ' + selected[0].name + '\n当前：' + app.runtime_label(selected[0].runtime_id) + '\n目标：' + app.runtime_label(target) + '\n确认后，该环境内全部应用将短暂停机并重启。', ui2.rect(0, y, width, 110), ui2.TextStyle{ size: 12, color: workbench_ink, lines: 4 })
			y += 124
			rows << button('server_upgrade', '确认切换此环境…', 0, y, 200, true, app.can_upgrade_selected_project())
			y += 52
		}
		for upgrade in state.upgrades {
			own := app.runtime_operation_sequence > 0 && app.runtime_operation_server == state.server_id && state.runtime_result.sequence == app.runtime_operation_sequence && state.runtime_result.action == 'upgrade' && state.runtime_result.target == selected[0].id && upgrade.id !in app.runtime_upgrade_before
			if upgrade.config_path != selected[0].config_path || (upgrade.finished() && !own) {
				continue
			}
			rows << state_notice('runtime_active_upgrade', if upgrade.phase == 'completed' {
				'本次切换已完成 · ' + selected[0].name
			} else {
				host.upgrade_phase_title(upgrade)
			}, if upgrade.error != '' {
				host.upgrade_error_hint(upgrade)
			} else if upgrade.phase == 'completed' {
				'此运行环境已使用 ' + app.runtime_label(upgrade.target_id) + '。'
			} else {
				'正在处理 ' + selected[0].name + ' 的版本切换。'
			}, ui2.rect(0, y, width, 104), if upgrade.phase == 'completed' {
				'good'
			} else if upgrade.finished() {
				'warning'
			} else {
				'info'
			})
			y += 120
		}
		history := state.upgrades.filter(it.finished() && it.config_path == selected[0].config_path)
		if history.len > 0 {
			rows << button('runtime_history_toggle', (if app.runtime_history_open {
				'收起'
			} else {
				'查看'
			}) + '历史切换记录（${history.len}）', 0, y, width, false, true)
			y += 48
			if app.runtime_history_open {
				for upgrade in history {
					result := if upgrade.phase == 'completed' {
						'该次切换已完成'
					} else if upgrade.phase == 'rolled_back' {
						'该次切换失败，已恢复原版本'
					} else {
						'该次切换未完成'
					}
					rows << ui2.label('upgrade_status_' + upgrade.id, '历史记录 · ' + selected[0].name + ' · ' + result + '\n' + app.runtime_label(upgrade.previous_id) + ' → ' + app.runtime_label(upgrade.target_id), ui2.rect(0, y, width, 72), ui2.TextStyle{ size: 12, color: workbench_muted, lines: 3 })
					y += 82
					rows << ui2.label('upgrade_log_' + upgrade.id, '该次操作日志：' + upgrade.config_path.all_before_last('/') + '/.desktop-upgrades/' + upgrade.id + '/runtime.log', ui2.rect(0, y, width, 56), ui2.TextStyle{ size: 11, color: workbench_muted, lines: 3 })
					y += 68
				}
			}
		}
	}
	result := state.runtime_result
	if app.runtime_form_error != '' {
		rows << state_notice('runtime_operation_error', '无法继续', app.runtime_form_error, ui2.rect(0, y, width, 96), 'warning')
		y += 112
	} else if app.runtime_operation_sequence > 0 && app.runtime_operation_server == state.server_id && result.sequence == app.runtime_operation_sequence && (result.error || result.action != 'upgrade') {
		rows << state_notice('runtime_operation_result', if result.error {
			'本次操作未完成'
		} else if result.action == 'install' {
			'运行包安装完成'
		} else {
			'运行环境创建完成'
		}, result.message, ui2.rect(0, y, width, 104), if result.error { 'warning' } else { 'info' })
		y += 120
	} else if busy {
		rows << label('runtime_operation_busy', '正在处理当前请求，请稍候…', 0, y, width, 12, workbench_muted)
		y += 40
	}
	if !app.runtime_create_open {
		rows << button('runtime_create_open', '新建运行环境…', 0, y, 180, false, !busy)
	}
	return rows
}

fn runtime_create_form(app &Workshop, width f64, top f64) []ui2.Element {
	mut rows := []ui2.Element{}
	mut y := top
	state := app.server_snapshot
	editable := !app.server_busy && !state.busy && !state.upgrades.any(!it.finished()) && !app.deployment_running()
	rows << label('server_create_heading', '新建远端运行环境', 0, y, width, 20, workbench_ink)
	y += 38
	rows << input('server_instance_name', app.server_instance_name, '运行环境名称', 0, y, width, editable)
	y += 51
	rows << choice_button('server_template_environment', '仅基础环境（推荐）', 0, y, width, app.server_template == 2, editable)
	y += 44
	rows << choice_button('server_template_http', 'HTTP 入门', 0, y, (width - 12) / 2, app.server_template == 0, editable)
	rows << choice_button('server_template_api', 'JSON API', (width + 12) / 2, y, (width - 12) / 2, app.server_template == 1, editable)
	y += 53
	rows << label('server_ports_label', '业务监听端口 / Admin 端口（均通过 SSH 访问）', 0, y, width, 12, workbench_muted)
	rows << input('server_web_port', app.server_web_port, '19881', 0, y + 24, 150, editable && app.server_template != 2)
	rows << input('server_admin_port', app.server_admin_port, '2018', 166, y + 24, 150, editable)
	y += 79
	rows << label('server_instance_path', state.root + '/instances/' + app.server_instance_name, 0, y, width, 11, workbench_muted)
	rows << button('server_create', '创建、启动并打开 Admin UI', 0, y + 30, 260, true, editable && app.selected_server_runtime() != '')
	return rows
}
