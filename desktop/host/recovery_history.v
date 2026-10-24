module host

import config

pub struct RecoveryVersionView {
pub:
	id string
	number int
	confirmed_at string
	file_count int
	latest bool
	saved bool
}

pub struct HistoryComparison {
pub:
	before_id string
	after_id string
	before_label string
	after_label string
	files []ConfigFileDiff
	fields []ConfigFieldDiff
	message string
}

fn (m &Manager) recovery_version(id string) !RecoveryVersion {
	for version in m.recovery_history {
		if id != '' && version.id == id { return version }
	}
	return error('所选历史版本不存在或已超出保留范围，请重新选择。')
}

fn (m &Manager) recovery_history_views() []RecoveryVersionView {
	mut result := []RecoveryVersionView{}
	for i := m.recovery_history.len - 1; i >= 0; i-- {
		v := m.recovery_history[i]
		result << RecoveryVersionView{id: v.id, number: v.number, confirmed_at: v.confirmed_at, file_count: v.sources.len,
			latest: v.id == m.recovery_id, saved: v.id in m.recovery_persisted_ids}
	}
	return result
}

pub fn (mut m Manager) compare_history_versions(before_id string, after_id string) ! {
	m.history_comparison = HistoryComparison{}
	before := m.recovery_version(before_id)!
	after := m.recovery_version(after_id)!
	files := config_file_diffs(before.revisions, after.revisions)
	// Compile archived source sets using overrides only; never temporarily rewrite live files.
	old_plan := config.load_runtime_plan_with_overrides(m.project.config_path, recovery_overrides(before.sources)) or {
		m.history_comparison = HistoryComparison{before_id: before_id, after_id: after_id, before_label: '版本 ${before.number} · ${before.confirmed_at}', after_label: '版本 ${after.number} · ${after.confirmed_at}', files: files, message: '文件差异可查看；历史版本在当前环境中无法通过整项目编译，字段差异不可用。'}
		return
	}
	new_plan := config.load_runtime_plan_with_overrides(m.project.config_path, recovery_overrides(after.sources)) or {
		m.history_comparison = HistoryComparison{before_id: before_id, after_id: after_id, before_label: '版本 ${before.number} · ${before.confirmed_at}', after_label: '版本 ${after.number} · ${after.confirmed_at}', files: files, message: '文件差异可查看；目标版本在当前环境中无法通过整项目编译，字段差异不可用。'}
		return
	}
	old_fields := config_component_fields_for_plan(old_plan, before.revisions, m.field_salt) or { return error('无法生成脱敏历史差异。') }
	new_fields := config_component_fields_for_plan(new_plan, after.revisions, m.field_salt) or { return error('无法生成脱敏历史差异。') }
	m.history_comparison = HistoryComparison{before_id: before_id, after_id: after_id, before_label: '版本 ${before.number} · ${before.confirmed_at}', after_label: '版本 ${after.number} · ${after.confirmed_at}', files: files,
		fields: config_field_diffs(old_fields, new_fields), message: '对比完成，当前项目配置未改动。'}
}
