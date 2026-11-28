module main

import os
import host
import ui2

fn config_status_view(app &Workshop, x f64, y f64, width f64) ui2.Element {
	path := app.projects[app.selected].config_path
	status := app.config_statuses[path] or { host.ConfigStatus{} }
	running := app.snapshot.phase == .running
	title, detail, tone := config_status_copy(app.snapshot, status)
	bg, color := state_colors(tone)
	return ui2.view('config_status_card', ui2.rect(x, y, width, 81), ui2.BoxStyle{bg: bg, radius: 8, border_color: color, border_left: 3}, [
		ui2.label('config_effectiveness', title, ui2.rect(16, 8, width - 236, 20), ui2.TextStyle{size: 13, bold: true, color: color}),
		label('config_changes', detail, 16, 31, width - 236, 11, workbench_colors.muted),
		label('config_checked', if running && status.checked_at != '' { ui_text('整项目检查 ${status.checked_at} · 每 2 秒刷新') } else { ui_text('仅检查工作台拥有的实例') }, 12, 53, width - 24, 10, workbench_colors.muted),
		button(if status.recovery_available && !status.pending && status.state != .unavailable { 'history_open' } else { 'config_diff' }, if status.recovery_available && !status.pending && status.state != .unavailable { ui_text('版本历史') } else { ui_text('差异详情') }, width - 208, 9, 94, false, app.local_command_enabled(if status.recovery_available && !status.pending && status.state != .unavailable { 'history_open' } else { 'config_diff' })),
		button(if status.pending { 'apply_restart' } else { 'check_config' }, if status.pending { ui_text('重启并生效') } else { ui_text('检查生效') }, width - 106, 9, 94, status.pending, app.local_command_enabled(if status.pending { 'apply_restart' } else { 'check_config' })),
	])
}

// Presentation only: keep an unavailable check distinct from confirmed effectiveness.
fn config_status_copy(snapshot host.Snapshot, status host.ConfigStatus) (string, string, string) {
	if snapshot.phase == .starting { return '正在启动项目', '就绪后自动检查整个项目，请稍候。', 'info' }
	if snapshot.phase == .stopping { return '正在停止项目', '等待当前实例退出，请稍候。', 'info' }
	if snapshot.phase == .failed {
		detail := if snapshot.can_force { '实例尚未退出，请先强制停止后重试。' } else if snapshot.pid > 0 { '正在结束本次实例，可在下方查看日志。' } else { '查看下方日志定位原因，修正后点击“重新启动”。' }
		return '项目未能运行', detail, 'danger'
	}
	if status.state == .unavailable { return '生效状态未确认', '检查未成功，保留上次结果；稍后自动重试。', 'warning' }
	if status.pending {
		if snapshot.phase == .running { return '待重启生效', '新配置尚未生效。重启后自动检查整个项目。', 'warning' }
		return '配置待启动生效', '启动项目后，自动检查整个项目的配置。', 'warning'
	}
	if snapshot.phase != .running { return '项目未运行', '启动项目后，自动检查配置生效状态。', 'info' }
	if status.state == .effective { return '配置已生效', '当前运行计划与项目配置一致。', 'good' }
	return '正在检查配置', '正在检查整个项目，请稍候。', 'info'
}

fn (mut app Workshop) open_config_diff_source(index int) {
	status := app.config_statuses[app.projects[app.selected].config_path] or { return }
	if index < 0 || index >= (status.files.len + status.affected_sources.len) || app.snapshot.phase != .running { return }
	file := if index < status.files.len { status.files[index] } else { status.affected_sources[index - status.files.len] }
	if !file.editable { return }
	next := app.sequence + 1
	select {
		app.worker.commands <- host.Command{action: .open_config, sequence: next, config_source: file.path} { app.sequence = next }
		else { app.notice = '操作正在处理，请稍候。' }
	}
}

fn config_diff_view(app &Workshop, width f64) []ui2.Element {
	project := app.projects[app.selected]
	status := app.config_statuses[project.config_path] or { host.ConfigStatus{} }
	mut rows := [
		label('diff_breadcrumb', project.name + ui_text(' / 配置差异'), 0, 25, width, 12, workbench_colors.muted),
		label('diff_title', if app.snapshot.phase != .running { ui_text('已生效版本 · 恢复与差异') } else if status.state == .unavailable { ui_text('配置检查失败 · 差异详情') } else if status.pending { ui_text('待生效配置 · 差异详情') } else { ui_text('配置已生效 · 差异详情') }, 0, 65, width, 24, workbench_colors.ink),
		button('config_diff_close', ui_text('返回工作台'), 0, 108, 104, false, true),
		button('check_config', ui_text('重新检查'), 116, 108, 94, false, app.snapshot.phase == .running),
		button('restart', ui_text('重启并检查'), 222, 108, 112, true, app.snapshot.phase == .running),
		button('history_open', ui_text('版本历史'), 346, 108, 112, false, app.snapshot.phase in [.running, .stopped, .failed] && status.recovery_available),
	]
	lines := [ui_text('项目入口：') + project.config_path, ui_text('检查时间：') + status.checked_at,
		ui_text('操作提示：') + if app.notice != '' { app.notice } else { ui_text(app.snapshot.message) },
		if app.snapshot.phase != .running { ui_text('项目未运行；恢复后启动项目检查生效。') } else if status.state == .unavailable { ui_text('检查失败，以下为上次成功检查的差异。') } else if !status.pending { ui_text('配置已生效，没有待执行差异。') } else { ui_text('配置尚未生效 · 请在宿主重启') },
		ui_text('受影响 Relay：') + if status.relays.len > 0 { status.relays.join(', ') } else { ui_text('无') },
		ui_text('受影响 Pipeline：') + if status.pipelines.len > 0 { status.pipelines.join(', ') } else { ui_text('无') },
		ui_text('文件与上次确认已生效的版本比较。')]
	body := ui2.text_area('diff_summary', lines.join('\n'), ui2.rect(0, 159, width, 132), ui2.BoxStyle{bg: workbench_colors.sidebar, radius: 6}, ui2.TextStyle{size: 11, color: workbench_colors.ink, font_family: workbench_detail_font()})
	rows << ui2.Element{...body, readonly: true}
	mut y := 311.0
	if status.pending {
		rows << label('diff_fields_title', ui_text('Relay / Pipeline 字段变化'), 0, y, width, 16, workbench_colors.ink)
		y += 35
		mut field_lines := []string{}
		for field in status.fields {
			name := if field.kind == 'Relay' && field.field.starts_with('options.') { field.field.all_after('options.') } else if field.kind == 'Relay' && field.field == 'ingress' { 'listener' } else { field.field }
			field_lines << ['${ui_text(field.kind)} ${field.component} · ${name} · ${ui_text(field.change)}' + if field.redacted { ui_text('（敏感值已脱敏）') } else { '' }, ui_text('修改前：') + field.before, ui_text('修改后：') + field.after, ui_text('来源：') + if field.source_after != '' { field.source_after } else { field.source_before }, '']
		}
		for pipeline in status.pipelines {
			if !status.fields.any(it.kind == 'Pipeline' && it.component == pipeline) {
				field_lines << ui_text('Pipeline ${pipeline}：自身字段未变，受关联组件变更影响。')
			}
		}
		if field_lines.len == 0 { field_lines << ui_text('Relay / Pipeline 字段未变，差异来自其他组件。') }
		height := f64(if field_lines.len * 15 + 20 > 300 { 300 } else { field_lines.len * 15 + 20 })
		field_body := ui2.text_area('diff_field_values', field_lines.join('\n'), ui2.rect(0, y, width, height), ui2.BoxStyle{bg: workbench_colors.sidebar, radius: 6}, ui2.TextStyle{size: 11, color: workbench_colors.ink, font_family: workbench_detail_font()})
		rows << ui2.Element{...field_body, readonly: true}
		y += height + 24
	}
	if status.pending && status.files.len == 0 {
		rows << label('diff_no_files', ui_text('文件文本未变；差异可能来自环境引用或运行计划变化。'), 0, y, width, 12, workbench_colors.muted)
		y += 34
	}
	mut files := status.files.clone()
	files << status.affected_sources
	for i, file in files {
		if i == status.files.len {
			rows << label('diff_affected_sources', ui_text('受影响组件的其他来源（文件不一定有修改）'), 0, y, width, 13, workbench_colors.ink)
			y += 36
		}
		path := if file.path.starts_with(os.dir(project.config_path) + '/') { './' + file.path[os.dir(project.config_path).len + 1..] } else { file.path }
		rows << label('diff_file_${i}', ui_text(file.change) + ' · ' + path, 0, y, width, 13, workbench_colors.ink)
		rows << label('diff_declarations_${i}', ui_text('文件声明 Relay：') + (if file.relays.len > 0 { file.relays.join(', ') } else { ui_text('无') }) + '  /  Pipeline：' + (if file.pipelines.len > 0 { file.pipelines.join(', ') } else { ui_text('无') }), 0, y + 29, width, 11, workbench_colors.muted)
		rows << button('config_edit_${i}', if file.editable { ui_text('在 Admin UI 继续编辑 ↗') } else { ui_text('来源已移出项目') }, 0, y + 60, 205, false, file.editable && app.snapshot.phase == .running)
		y += 116
	}
	return rows
}
