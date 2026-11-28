module host

import crypto.sha256
import json2
import os

const recovery_max_bytes = 16 * 1024 * 1024

struct RecoveryVersion {
	version int = 1
	id string
	number int
	project string
	workdir string
	confirmed_at string
	sources []RecoverySource
	revisions []ConfigRevision
	store_root string
}

const recovery_history_limit = 20

struct RecoveryArchive {
	version int = 2
	versions []RecoveryVersion
}

// History is local project data, protected by current-user directory and file permissions.
pub fn new_persistent_manager() &Manager {
	return new_persistent_manager_at(os.join_path(workbench_data_dir(), 'recovery'))
}

// An isolated storage directory can be used by integration checks.
pub fn new_persistent_manager_at(directory string) &Manager {
	return &Manager{recovery_disk_root: directory}
}

fn recovery_identity(project Project) string {
	return json2.encode([os.abs_path(project.config_path), os.abs_path(project.workdir)])
}

fn (m &Manager) recovery_path() string {
	return os.join_path(m.recovery_disk_root, sha256.sum(recovery_identity(m.project).bytes()).hex() + '.history.json')
}

fn safe_recovery_path(path string) ! {
	mut current := os.abs_path(path)
	for {
		if os.is_link(current) { return error('unsafe_recovery_storage') }
		next := os.dir(current)
		if next == current { break }
		current = next
	}
}

fn (mut m Manager) persist_recovery_version() ! {
	if m.recovery_disk_root == '' { return }
	path := m.recovery_path()
	safe_recovery_path(path)!
	os.mkdir_all(m.recovery_disk_root)!
	safe_recovery_path(path)!
	if os.stat(m.recovery_disk_root)!.uid != u32(os.getuid()) { return error('foreign_recovery_storage') }
	os.chmod(m.recovery_disk_root, 0o700)!
	if os.exists(path) && (!os.is_file(path) || os.stat(path)!.uid != u32(os.getuid())) { return error('unsafe_recovery_version') }
	lease := lock_recovery_archive(path + '.lock')!
	defer { release_recovery_archive(lease) }
	if os.exists(path) {
		if m.recovery_disk_revision == '' || sha256.sum(os.read_bytes(path)!).hex() != m.recovery_disk_revision { return error('recovery_archive_changed') }
	} else if m.recovery_disk_revision != '' { return error('recovery_archive_removed') }
	mut retained := m.recovery_history.clone()
	if retained.len > recovery_history_limit { retained = retained[retained.len - recovery_history_limit..].clone() }
	mut value := json2.encode(RecoveryArchive{versions: retained}).bytes()
	for value.len > recovery_max_bytes && retained.len > 1 {
		retained = retained[1..].clone()
		value = json2.encode(RecoveryArchive{versions: retained}).bytes()
	}
	if value.len > recovery_max_bytes { return error('recovery_version_too_large') }
	temp := path + '.' + os.getpid().str() + '.' + m.recovery_id + '.tmp'
	defer { os.rm(temp) or {} }
	write_recovery_data(temp, value)!
	safe_recovery_path(path)!
	replace_recovery_data(temp, path)!
	m.recovery_history = retained
	m.recovery_persisted_ids = retained.map(it.id)
	m.recovery_disk_revision = sha256.sum(value).hex()
}

fn (mut m Manager) load_recovery_version() ! {
	if m.recovery_disk_root == '' { return }
	path := m.recovery_path()
	safe_recovery_path(path)!
	if !os.exists(path) { return }
	stat := os.stat(path)!
	if !os.is_file(path) || stat.uid != u32(os.getuid()) || stat.mode & 0o077 != 0 || stat.size > u64(recovery_max_bytes + 128) {
		return error('unsafe_recovery_version')
	}
	bytes := os.read_bytes(path)!
	archive := json2.decode[RecoveryArchive](bytes.bytestr())!
	if archive.version != 2 || archive.versions.len == 0 || archive.versions.len > recovery_history_limit { return error('invalid_recovery_archive') }
	versions := archive.versions
	mut ids := map[string]bool{}
	mut previous_number := 0
	for version in versions {
		if version.id == '' || ids[version.id] || version.number <= previous_number { return error('invalid_recovery_id') }
		ids[version.id] = true
		previous_number = version.number
		validate_recovery_version(version, m.project)!
	}
	version := versions.last()
	m.recovery_history = versions
	m.recovery_persisted_ids = versions.map(it.id)
	m.recovery_disk_revision = sha256.sum(bytes).hex()
	m.recovery_baseline = version.sources
	m.recovery_revisions = version.revisions
	m.recovery_at = version.confirmed_at
	m.recovery_id = version.id
	m.recovery_store_root = version.store_root
	m.recovery_confirmed = true
	m.recovery_saved = true
	m.recovery_generation++
	m.recovery_saved_generation = m.recovery_generation
}

fn (mut m Manager) open_recovery_version() {
	m.recovery_confirmed = false
	m.recovery_saved = false
	m.recovery_notice = ''
	m.recovery_history = []RecoveryVersion{}
	m.recovery_persisted_ids = []string{}
	m.recovery_disk_revision = ''
	m.recovery_id = ''
	m.history_comparison = HistoryComparison{}
	m.recovery_baseline = []RecoverySource{}
	m.recovery_revisions = []ConfigRevision{}
	m.pending_rollback = none
	m.rollback_preview = RollbackPreview{}
	m.load_recovery_version() or { m.recovery_notice = '无法读取版本历史，请检查文件权限或历史文件是否损坏；现有文件已保留。' }
}

fn (mut m Manager) offline_recovery_status() {
	m.config_status = ConfigStatus{recovery_available: m.recovery_confirmed, message: if m.recovery_confirmed { '已保存 ${m.recovery_history.len} 个版本 · 可查看历史和恢复' } else { m.recovery_notice }}
}

fn validate_recovery_version(version RecoveryVersion, project Project) ! {
	if version.version != 1 || version.project != project.config_path || version.workdir != project.workdir || version.confirmed_at == '' || version.sources.len == 0 || !version.sources.any(it.path == version.project) || version.store_root == '' {
		return error('foreign_recovery_version')
	}
	mut seen := map[string]bool{}
	for source in version.sources {
		if !source.exists || !os.is_abs_path(source.path) || os.abs_path(source.path) != source.path || seen[source.path] { return error('invalid_recovery_source') }
		seen[source.path] = true
		revisions := version.revisions.filter(it.source.path == source.path)
		if revisions.len != 1 || revisions[0].hash != sha256.sum(source.value.bytes()).hex() { return error('invalid_recovery_revision') }
	}
	if version.sources.len != version.revisions.len { return error('invalid_recovery_sources') }
}
