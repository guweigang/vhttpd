module main

import host

// A disconnected manager cannot confirm the process or the active revision.
// Both transports use the same configuration wording and severity rules.
struct WorkspaceRuntimeStatus {
	title string
	detail string
	tone string
}

fn workspace_runtime_status(app &Workshop) WorkspaceRuntimeStatus {
	remote := app.environment_id != ''
	mut snapshot := app.snapshot
	mut status := host.ConfigStatus{}
	mut connection := '本机'
	if remote {
		s := app.remote_snapshot
		if !s.connected && !s.restarting {
			return WorkspaceRuntimeStatus{ui_text('运行状态未确认'), ui_text('管理连接：') + ui_text('未连接') + '\n' + ui_text('重新连接后检查进程与整项目配置，断开连接不会停止远端进程。'), 'warning'}
		}
		connection = '远端管理已连接'
		phase := if s.restarting { host.Phase.starting } else if s.instance.startup_failed() { host.Phase.failed } else if s.instance.ready { host.Phase.running } else { host.Phase.stopped }
		snapshot = host.Snapshot{phase: phase}
		status = s.config_status
	} else if app.selected >= 0 && app.selected < app.projects.len {
		status = app.config_statuses[app.projects[app.selected].config_path] or { host.ConfigStatus{} }
	}
	configuration, detail, tone := config_status_copy(snapshot, status)
	process := match snapshot.phase {
		.running { '运行中' }
		.starting { if remote { '正在重启并检查生效' } else { '启动中' } }
		.stopping { '停止中' }
		.failed { '启动或运行失败' }
		else { if remote { '管理已连接 · 业务未就绪' } else { '已停止' } }
	}
	title := if snapshot.phase == .running { ui_text(process) + ' · ' + ui_text(configuration) } else { ui_text(process) }
	return WorkspaceRuntimeStatus{title, ui_text('管理连接：') + ui_text(connection) + '\n' + ui_text('配置：') + ui_text(configuration) + ' · ' + ui_text(detail), tone}
}
