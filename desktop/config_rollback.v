module main

import host
import ui2

fn (mut app Workshop) confirm_config_restore() {
	preview := app.snapshot.rollback_preview
	if !preview.available || preview.id == '' || app.snapshot.phase !in [.running, .stopped, .failed] { return }
	next := app.sequence + 1
	select {
		app.worker.commands <- host.Command{action: .restore_rollback, sequence: next, rollback_id: preview.id} { app.sequence = next }
		else { app.notice = '操作正在处理，请稍候。' }
	}
}

fn config_rollback_view(app &Workshop, width f64) []ui2.Element {
	preview := app.snapshot.rollback_preview
	need_restart := preview.id == '' && app.snapshot.phase == .running && app.snapshot.config_status.pending
	need_start := preview.id == '' && app.snapshot.phase in [.stopped, .failed] && app.snapshot.message.contains('配置文件已恢复')
	mut rows := [
		label('rollback_breadcrumb', app.projects[app.selected].name + ' / 配置恢复', 0, 25, width, 12, workbench_muted),
		label('rollback_title', '恢复到所选已生效版本', 0, 65, width, 24, workbench_ink),
		button('rollback_close', if app.show_history { '返回版本历史' } else { '返回差异详情' }, 0, 108, 125, false, true),
		button('preview_rollback', '重新预览', 137, 108, 100, false, app.snapshot.phase in [.running, .stopped, .failed]),
		button(if need_restart { 'restart' } else if need_start { 'start' } else { 'restore_rollback' }, if need_restart { '重启并检查' } else if need_start { '启动并检查' } else { '恢复这份预览' }, 249, 108, 142, true, need_restart || need_start || (preview.available && app.snapshot.phase in [.running, .stopped, .failed])),
	]
	mut lines := []string{}
	if preview.id == '' {
		if app.snapshot.phase == .running && app.snapshot.config_status.state == .effective { lines << '整项目检查确认：配置已生效。' }
		lines << if app.snapshot.message != '' { app.snapshot.message } else { '正在生成整项目回滚预览…' }
	} else {
		lines << ['目标版本：' + preview.version_label + '\n确认时间：' + preview.baseline_at, preview.message, '范围：所选版本的主配置与全部 include。', '', '恢复文件与 include 关系：']
		for file in preview.files { lines << file.action + ' · ' + file.path }
		lines << ['', '字段变化（当前 → 恢复目标）：']
		for field in preview.fields {
			name := if field.kind == 'Relay' && field.field.starts_with('options.') { field.field.all_after('options.') } else { field.field }
			lines << ['${field.kind} ${field.component} · ${name} · ${field.change}' + if field.redacted { '（敏感值已脱敏）' } else { '' }, '当前：' + field.before, '恢复为：' + field.after, '']
		}
		lines << ['恢复前会再次检查文件，预览后发生外部修改将拒绝覆盖。', if app.snapshot.phase == .running { '恢复后自动按整个项目检查生效；若仍有运行差异，可回工作台重启。' } else { '恢复后校验整个项目；当前项目未运行，启动后自动检查生效。' }]
	}
	body := ui2.text_area('rollback_details', lines.join('\n'), ui2.rect(0, 159, width, 480), ui2.BoxStyle{bg: workbench_sidebar, radius: 6}, ui2.TextStyle{size: 11, color: workbench_ink, font_family: 'Menlo'})
	rows << ui2.Element{...body, readonly: true}
	return rows
}
