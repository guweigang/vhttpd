module host

import admin_state_store
import config
import crypto.rand
import crypto.sha256
import os
import time

// Raw contents stay in the worker-owned Manager. Never put these in Snapshot or diagnostics.
struct RecoverySource {
	path string
	exists bool
	value string
	mode int
}

pub struct RollbackFileView {
pub:
	path string
	action string
}

pub struct RollbackPreview {
pub:
	id string
	available bool
	baseline_at string
	version_id string
	version_label string
	files []RollbackFileView
	fields []ConfigFieldDiff
	message string
}

struct PendingRollback {
	id string
	project string
	generation u64
	inputs []RecoverySource
	targets []RecoverySource
}

fn recovery_source(path string) !RecoverySource {
	mut parent := os.dir(os.abs_path(path))
	for {
		if os.is_link(parent) { return error('unsafe recovery parent') }
		next := os.dir(parent)
		if next == parent { break }
		parent = next
	}
	if os.is_link(path) { return error('unsafe recovery source') }
	if !os.exists(path) { return RecoverySource{path: path} }
	if !os.is_file(path) { return error('recovery source is not a file') }
	return RecoverySource{path: path, exists: true, value: os.read_file(path)!, mode: int(os.stat(path)!.mode & 0o777)}
}

fn recovery_sources(revisions []ConfigRevision) ![]RecoverySource {
	mut result := []RecoverySource{}
	for revision in revisions {
		source := recovery_source(revision.source.path)!
		if !source.exists || sha256.sum(source.value.bytes()).hex() != revision.hash { return error('source changed') }
		result << source
	}
	return result
}

fn verify_recovery_inputs(inputs []RecoverySource) ! {
	for input in inputs {
		if recovery_source(input.path)! != input { return error('rollback_preview_stale') }
	}
}

fn recovery_overrides(sources []RecoverySource) map[string]string {
	mut values := map[string]string{}
	for source in sources { values[source.path] = source.value }
	return values
}

fn (mut m Manager) record_recovery_baseline(revisions []ConfigRevision, sources []RecoverySource, store_root string) {
	if !m.recovery_confirmed || m.recovery_baseline != sources {
		m.recovery_generation++
		m.recovery_saved = false
		m.recovery_at = time.now().format_ss()
		m.recovery_id = rand.bytes(16) or { m.recovery_notice = '无法生成安全版本标识。'; return }.hex()
		m.recovery_baseline = sources
		m.recovery_revisions = revisions
		m.recovery_store_root = store_root
		m.rollback_preview = RollbackPreview{}
		m.pending_rollback = none
	}
	m.recovery_confirmed = true
	if !m.recovery_history.any(it.id == m.recovery_id) {
		m.recovery_history << RecoveryVersion{id: m.recovery_id, number: if m.recovery_history.len > 0 { m.recovery_history.last().number + 1 } else { 1 }, project: m.project.config_path, workdir: m.project.workdir,
			confirmed_at: m.recovery_at, sources: sources, revisions: revisions, store_root: store_root}
	}
	if !m.recovery_saved || m.recovery_saved_generation != m.recovery_generation {
		m.persist_recovery_version() or {
			m.recovery_notice = '本次已生效版本尚未保存到历史，请检查本地目录权限。'
			return
		}
		m.recovery_saved = m.recovery_disk_root != ''
		m.recovery_saved_generation = m.recovery_generation
		m.recovery_notice = ''
	}
}

pub fn (mut m Manager) preview_config_rollback() ! {
	m.preview_history_rollback(m.recovery_id)!
}

pub fn (mut m Manager) preview_history_rollback(version_id string) ! {
	m.pending_rollback = none
	m.rollback_preview = RollbackPreview{}
	version := m.recovery_version(version_id)!
	if m.phase !in [.running, .stopped, .failed] || !m.recovery_confirmed { return error('当前项目尚无可用的已确认生效版本。') }
	mut inputs := []RecoverySource{}
	for source in version.sources { inputs << recovery_source(source.path) or { return error('无法安全读取来源文件，请检查路径和权限。') } }
	current := config_revisions(m.project.config_path) or { []ConfigRevision{} }
	for revision in current {
		if !inputs.any(it.path == revision.source.path) {
			inputs << recovery_source(revision.source.path) or { return error('无法读取当前来源文件。') }
		}
	}
	root := m.project.config_path
	overrides := recovery_overrides(version.sources)
	plan := config.load_runtime_plan_with_overrides(root, overrides) or { return error('回滚目标未通过整项目校验；原始文件未修改。') }
	target_fields := config_component_fields_for_plan(plan, version.revisions, m.field_salt) or { return error('无法生成脱敏的回滚预览。') }
	current_fields := config_component_fields(root, current, m.field_salt) or { []ConfigComponentFields{} }
	mut files := []RollbackFileView{}
	for target in version.sources {
		input := inputs.filter(it.path == target.path)[0]
		if !input.exists || input.value != target.value || input.mode != target.mode {
			files << RollbackFileView{path: target.path, action: if input.exists { '恢复已生效内容与权限' } else { '重新创建已生效来源' }}
		}
	}
	for input in inputs {
		if !version.sources.any(it.path == input.path) { files << RollbackFileView{path: input.path, action: '移出 include 关系，文件保留'} }
	}
	if files.len == 0 { return error('来源文件已经与所选版本一致；请检查运行计划或环境引用。') }
	verify_recovery_inputs(inputs) or { return error('预览期间配置发生变化，请重新预览。') }
	id := rand.bytes(16)!.hex()
	m.pending_rollback = PendingRollback{id: id, project: root, generation: m.recovery_generation, inputs: inputs, targets: version.sources}
	m.rollback_preview = RollbackPreview{id: id, available: true, baseline_at: version.confirmed_at, version_id: version.id, version_label: '版本 ${version.number}', files: files,
		fields: if current_fields.len > 0 { config_field_diffs(current_fields, target_fields) } else { []ConfigFieldDiff{} },
		message: if current_fields.len > 0 { '整项目校验通过。确认后统一恢复；新增来源文件保留，敏感值不显示。' } else { '回滚目标整项目校验通过。当前配置无法编译，字段预览不可用；可按以下文件恢复。' }}
	m.rollback_preview = RollbackPreview{...m.rollback_preview, message: m.rollback_preview.message + if version.id in m.recovery_persisted_ids { '\n版本已保存，重新打开工作台后仍可恢复。' } else { '\n此版本尚未保存，仅在本次会话可用。' }}
	m.message = '回滚预览已生成，尚未修改项目文件。'
}

pub fn (mut m Manager) restore_config_rollback(id string) ! {
	pending := m.pending_rollback or { return error('请先生成回滚预览。') }
	if m.phase !in [.running, .stopped, .failed] || id == '' || pending.id != id || pending.project != m.project.config_path || pending.generation != m.recovery_generation {
		return error('回滚预览已失效，请重新预览。')
	}
	m.pending_rollback = none
	m.rollback_preview = RollbackPreview{}
	root := pending.project
	inputs := pending.inputs
	overrides := recovery_overrides(pending.targets)
	mut changes := []admin_state_store.ConfigFileRestore{}
	// Restore include fragments before reconnecting the main configuration.
	for target in pending.targets.filter(it.path != root) {
		input := inputs.filter(it.path == target.path)[0]
		changes << admin_state_store.ConfigFileRestore{path: target.path, original: input.value, original_exists: input.exists, value: target.value, mode: target.mode}
	}
	for target in pending.targets.filter(it.path == root) {
		input := inputs.filter(it.path == target.path)[0]
		changes << admin_state_store.ConfigFileRestore{path: target.path, original: input.value, original_exists: input.exists, value: target.value, mode: target.mode}
	}
	mut store := admin_state_store.FileStore.new(m.recovery_store_root) or { return error('无法取得配置恢复存储，请检查权限。') }
	store.restore_config_files(changes, fn [root, overrides, inputs] () ! {
		verify_recovery_inputs(inputs)!
		config.load_runtime_plan_with_overrides(root, overrides)!
	}, fn [root, pending] () ! {
		config.load_runtime_plan_file(root)!
		for target in pending.targets {
			if recovery_source(target.path)! != target { return error('restored source changed') }
		}
		// Detached sources are retained byte-for-byte, not deleted.
		for input in pending.inputs {
			if !pending.targets.any(it.path == input.path) && recovery_source(input.path)! != input { return error('detached source changed') }
		}
	}) or {
		m.refresh_config_status()
		if err.msg().contains('compensation_failed') { return error('恢复失败，且部分文件未能撤回；请检查项目文件并重新预览。') }
		return error('恢复未完成：配置已变化，或校验 / 写入失败。本次已写入内容已撤回，请重新预览。')
	}
	if m.phase == .running { m.refresh_config_status() } else { m.offline_recovery_status() }
	m.message = if m.phase != .running { '配置文件已恢复，整项目校验通过；启动后自动检查生效。' } else if m.config_status.state == .effective { '已恢复所选版本，整项目检查确认已生效。' } else { '配置文件已恢复，整项目尚未确认生效；请检查状态，必要时在宿主重启。' }
}
