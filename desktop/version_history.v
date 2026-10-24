module main

import host
import ui2

fn (mut app Workshop) open_version_history() {
	app.show_history = true
	app.show_history_diff = false
	app.history_custom_base = false
	versions := app.snapshot.recovery_history
	if versions.len > 0 {
		app.history_after = versions[0].id
		app.history_before = versions[if versions.len > 1 { 1 } else { 0 }].id
	}
}

fn (mut app Workshop) compare_selected_versions() {
	if app.history_before == '' || app.history_after == '' { return }
	app.show_history_diff = true
	next := app.sequence + 1
	select {
		app.worker.commands <- host.Command{action: .compare_history, sequence: next, before_id: app.history_before, version_id: app.history_after} { app.sequence = next }
		else { app.notice = '操作正在处理，请稍候。' }
	}
}

fn (mut app Workshop) preview_selected_version(id string) {
	app.show_rollback = true
	app.rollback_version = id
	next := app.sequence + 1
	select {
		app.worker.commands <- host.Command{action: .preview_rollback, sequence: next, version_id: id} { app.sequence = next }
		else { app.notice = '操作正在处理，请稍候。' }
	}
}

fn version_history_view(app &Workshop, width f64) []ui2.Element {
	if app.show_history_diff { return history_comparison_view(app, width) }
	versions := app.snapshot.recovery_history
	mut rows := [
		label('history_breadcrumb', app.projects[app.selected].name + ' / 已生效版本', 0, 25, width, 12, workbench_muted),
		label('history_title', '版本历史', 0, 65, width, 24, workbench_ink),
		button('history_close', '返回工作台', 0, 108, 125, false, true),
		label('history_help', '查看变化只读 · 恢复前可预览', 143, 116, width - 143, 11, workbench_muted),
		label('history_retention', '只记录已确认生效的配置，自动保留最近最多 20 个版本。', 0, 157, width, 11, workbench_muted),
	]
	mut y := 190.0
	for v in versions {
		rows << label('version_' + v.id, '版本 ${v.number} · ' + v.confirmed_at + if v.latest { ' · 最近生效' } else { '' }, 0, y, width, 13, workbench_ink)
		rows << label('version_state_' + v.id, '${v.file_count} 个配置来源 · ' + if v.saved { '已保存' } else { '尚未保存' }, 0, y + 23, width, 10, workbench_muted)
		rows << button('history_before_' + v.id, if app.history_before == v.id { '对比基准 ✓' } else { '设为对比基准' }, 0, y + 44, 128, false, true)
		rows << button('history_view_' + v.id, '查看变化', 140, y + 44, 112, false, true)
		rows << button('history_restore_' + v.id, if !history_can_restore(app, v.id) && v.latest { '当前已生效' } else { '恢复此版本' }, 264, y + 44, 148, false, history_can_restore(app, v.id))
		y += 94
	}
	if versions.len == 0 { rows << label('history_empty', '首次启动并确认配置生效后，会自动记录版本。', 0, y, width, 12, workbench_muted) }
	return rows
}

fn history_comparison_view(app &Workshop, width f64) []ui2.Element {
	mut rows := [
		label('compare_breadcrumb', app.projects[app.selected].name + ' / 版本历史', 0, 25, width, 12, workbench_muted),
		label('compare_title', '版本变化', 0, 65, width, 24, workbench_ink),
		button('history_list', '返回版本列表', 0, 108, 125, false, true),
		button('history_restore_' + app.history_before, history_restore_title(app, app.history_before), 137, 108, 150, false, history_can_restore(app, app.history_before)),
		button('history_restore_' + app.history_after, history_restore_title(app, app.history_after), 299, 108, 150, false, history_can_restore(app, app.history_after)),
	]
	mut lines := []string{}
	comparison := app.snapshot.history_comparison
	if comparison.before_id == app.history_before && comparison.after_id == app.history_after && comparison.before_id != '' {
		lines << [comparison.message, '对比基准：' + comparison.before_label, '查看版本：' + comparison.after_label, '', '配置来源变化：']
		for file in comparison.files { lines << file.change + ' · ' + file.path }
		lines << ['', '字段变化（对比基准 → 查看版本）：']
		for field in comparison.fields {
			name := if field.kind == 'Relay' && field.field.starts_with('options.') { field.field.all_after('options.') } else { field.field }
			source := if field.source_before == field.source_after { field.source_after } else { field.source_before + ' → ' + field.source_after }
			lines << ['${field.kind} ${field.component} · ${name}' + if field.redacted { '（已脱敏）' } else { '' }, '修改前：' + field.before, '修改后：' + field.after, '来源：' + source, '']
		}
		if comparison.files.len == 0 && comparison.fields.len == 0 { lines << '两个版本没有文件或字段差异。' }
	} else {
		lines << if app.snapshot.message != '' { app.snapshot.message } else { '正在读取版本变化…' }
	}
	body := ui2.text_area('history_diff', lines.join('\n'), ui2.rect(0, 159, width, 480), ui2.BoxStyle{bg: workbench_sidebar, radius: 6}, ui2.TextStyle{size: 11, color: workbench_ink, font_family: 'Menlo'})
	rows << ui2.Element{...body, readonly: true}
	return rows
}

fn history_can_restore(app &Workshop, id string) bool {
	if id == '' || app.snapshot.phase !in [.running, .stopped, .failed] { return false }
	for version in app.snapshot.recovery_history {
		if version.id == id {
			return !(version.latest && app.snapshot.phase == .running && app.snapshot.config_status.state == .effective)
		}
	}
	return false
}

fn history_restore_title(app &Workshop, id string) string {
	for version in app.snapshot.recovery_history {
		if version.id == id { return '恢复版本 ${version.number}…' }
	}
	return '恢复版本…'
}
