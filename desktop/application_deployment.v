module main

import host
import ui2

fn (mut app Workshop) deployment_command(action host.ServerAction) {
	if app.deployment_local < 0 || app.deployment_local >= app.projects.len { return }
	next := app.server_sequence + 1
	command := host.ServerCommand{ sequence: next, action: action, project_id: app.deployment_remote, local_project: app.projects[app.deployment_local], deployment_id: app.server_snapshot.deployment_preview.id }
	select {
		app.server_worker.commands <- command {
			app.server_sequence = next
			app.server_busy = true
		}
		else {
		}
	}
}

fn (app &Workshop) deployment_running() bool {
	return app.server_snapshot.deployments.any(!it.finished())
}

fn (mut app Workshop) handle_deployment_event(event string) bool {
	if event == 'deploy_open' {
		app.show_deployment = true
		app.deployment_local = if app.selected >= 0 && app.selected < app.projects.len {
			app.selected
		} else {
			0
		}
		app.deployment_remote = app.remote_id
		if !app.remote_profiles.any(it.id == app.deployment_remote) && app.remote_profiles.len > 0 {
			app.deployment_remote = app.remote_profiles[0].id
		}
		return true
	}
	if !event.starts_with('deploy_') { return false }
	if event == 'deploy_close' {
		if !app.server_busy {
			if app.server_snapshot.deployment_preview.id != '' {
				app.deployment_command(.discard_deploy)
			}
			app.show_deployment = false
		}
		return true
	}
	if app.server_busy || app.server_snapshot.busy || app.deployment_running() { return true }
	if event.starts_with('deploy_local_') {
		app.deployment_local = event.all_after('deploy_local_').int()
		if app.server_snapshot.deployment_preview.id != '' {
			app.deployment_command(.discard_deploy)
		}
	} else if event.starts_with('deploy_target_') {
		app.deployment_remote = event.all_after('deploy_target_')
		if app.server_snapshot.deployment_preview.id != '' {
			app.deployment_command(.discard_deploy)
		}
	} else if event == 'deploy_prepare' {
		app.deployment_command(.prepare_deploy)
	} else if event == 'deploy_connect' {
		for p in app.remote_profiles {
			if p.id == app.deployment_remote {
				app.select_remote_profile(p)
				app.show_deployment = false
				app.show_remote = true
				app.show_servers = false
				app.show_runtime = false
				app.connect_remote_project(p)
				break
			}
		}
	} else if event == 'deploy_commit' {
		preview := app.server_snapshot.deployment_preview
		selected := app.remote_profiles.filter(it.id == app.deployment_remote)
		if preview.id != '' && selected.len == 1 && preview.config_path == selected[0].config_path && ui2.confirm('部署并重启应用', '将把预览中的源码、静态资源和全部 include 一起部署到 ' + selected[0].name + '。远端端口与认证保持不变；业务短暂中断，失败时自动恢复原应用。') {
			app.deployment_command(.deploy)
		}
	}
	return true
}

fn application_deployment_view(app &Workshop, width f64) []ui2.Element {
	mut rows := [
		label('deploy_title', '部署本地应用', 0, 30, width - 120, 24, workbench_ink),
		button('deploy_close', '返回项目', width - 110, 29, 110, false, !app.server_busy),
		label('deploy_help', 'SSH Linux 手工实例；需先安装支持应用部署协议的运行包。', 0, 72, width, 12, workbench_muted),
	]
	mut y := 115.0
	enabled := !app.server_busy && !app.server_snapshot.busy && !app.deployment_running()
	rows << label('deploy_source_title', '本地项目 · 源码、静态资源与 include', 0, y, width, 14, workbench_ink)
	y += 34
	for i, p in app.projects {
		rows << sidebar_button('deploy_local_${i}', p.name, ui2.rect(0, y, width, 34), false, i == app.deployment_local, enabled, .left)
		y += 42
	}
	rows << label('deploy_target_title', '目标远端实例 · SSH 手工启动', 0, y + 8, width, 14, workbench_ink)
	y += 46
	for p in app.remote_profiles {
		rows << sidebar_button('deploy_target_${p.id}', p.name + ' · ' + p.ssh_host, ui2.rect(0, y, width, 34), false, p.id == app.deployment_remote, enabled, .left)
		y += 42
	}
	targets := app.remote_profiles.filter(it.id == app.deployment_remote)
	connected := targets.len == 1 && app.server_snapshot.connected && app.server_snapshot.server_id == targets[0].server_id
	if !connected {
		rows << state_notice('deploy_connection', '先连接目标服务器', '选择远端实例后，连接其服务器。密码只在本次会话使用。', ui2.rect(0, y + 8, width, 88), 'info')
		y += 110
		rows << button('deploy_connect', '连接目标实例', 0, y, 160, true, targets.len == 1 && enabled)
		return rows
	}
	rows << state_notice('deploy_boundary', '保留远端运行环境', '保留监听地址、端口与认证；不覆盖 .env、日志、数据库、运行包和工作台状态。首版要求监听标识及协议一致；符号链接或目录外来源需先整理为项目内文件。', ui2.rect(0, y + 8, width, 110), 'info')
	y += 136
	if app.server_busy || app.server_snapshot.busy {
		rows << state_notice('deploy_busy', '正在处理部署操作', '正在准备预览或提交部署，请稍候；执行结果会同步到这里。', ui2.rect(0, y, width, 88), 'info')
		y += 106
	}
	rows << button('deploy_prepare', '预览并校验部署', 0, y, 175, true, enabled && app.projects.len > 0 && targets.len == 1)
	y += 52
	if app.server_snapshot.error {
		rows << state_notice('deploy_error', '预检或操作未完成', app.server_snapshot.message, ui2.rect(0, y, width, 110), 'danger')
		y += 128
	}
	preview := app.server_snapshot.deployment_preview
	if preview.id != '' && targets.len == 1 && preview.config_path == targets[0].config_path {
		changed := preview.files.filter(it.action != 'unchanged')
		rows << label('deploy_preview_title', '整项目预检通过 · ${changed.len} 个文件变更', 0, y, width, 16, workbench_ink)
		y += 34
		for i, file in changed {
			if i >= 40 {
				rows << label('deploy_more', '其余 ${changed.len - 40} 个文件同属本次部署包。', 0, y, width, 12, workbench_muted)
				y += 30
				break
			}
			rows << label('deploy_file_${i}', (match file.action {
				'add' { '新增' }
				'replace' { '替换' }
				'delete' { '移除' }
				else { '未变更' }
			}) + ' · ' + file.path, 0, y, width, 12, workbench_ink)
			y += 28
		}
		rows << label('deploy_preserved', '远端环境字段保留；凭据不在预览中展示。', 0, y + 4, width, 12, workbench_muted)
		y += 42
		rows << button('deploy_commit', '部署并重启', 0, y, 175, true, enabled)
		y += 52
	}
	if targets.len == 1 {
		for status in app.server_snapshot.deployments {
			if status.config_path == targets[0].config_path {
				tone := if status.phase == 'completed' {
					'good'
				} else if status.phase in ['rollback_failed', 'failed'] {
					'danger'
				} else if status.phase == 'rolled_back' {
					'warning'
				} else {
					'info'
				}
				rows << state_notice('deployment_status', host.application_deployment_title(status), if status.error == '' {
					'远端执行部署与恢复，断开 SSH 后仍会继续。完成后按整个项目检查生效。'
				} else {
					host.application_deployment_hint(status.error)
				}, ui2.rect(0, y, width, 110), tone)
				y += 128
				rows << ui2.label('deployment_log', '远端日志：' + status.config_path.all_before_last('/') + '/.desktop-deployments/' + status.id + '/runtime.log', ui2.rect(0, y, width, 60), ui2.TextStyle{ size: 11, color: workbench_muted, lines: 3 })
				y += 72
			}
		}
	}
	return rows
}
