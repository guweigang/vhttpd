module host

import crypto.sha256
import json2 as json
import os
import time

struct McpConfigVersion {
	id string
	created_at string
	revision string
	workspace SharedConfigWorkspace
}

struct McpConfigArchive {
	version int = 1
	identity string
	versions []McpConfigVersion
}

fn (s &ServerSession) config_history_identity(r McpOrdinaryRelayRequest, root string) string {
	peer := if r.target_id == '' { 'local' } else { json.encode([s.server.id, s.server.ssh_host, s.server.ssh_user, s.server.ssh_port.str(), r.target_id]) }
	return sha256.hexhash(peer + '\n' + root)
}

fn config_archive_path(identity string) string { return os.join_path(workbench_data_dir(), 'configuration-history', identity + '.json') }

fn config_archive_read(identity string) !McpConfigArchive {
	path := config_archive_path(identity)
	safe_recovery_path(path)!
	if !os.exists(path) { return McpConfigArchive{identity: identity} }
	st := os.stat(path)!
	if !os.is_file(path) || st.uid != u32(os.getuid()) || st.mode & 0o077 != 0 || st.size > u64(recovery_max_bytes) { return error('unsafe_config_history_archive') }
	archive := json.decode[McpConfigArchive](os.read_file(path)!)!
	if archive.version != 1 || archive.identity != identity || archive.versions.len > 20 { return error('invalid_config_history_archive') }
	mut ids := []string{}
	for version in archive.versions {
		if version.id == '' || version.id in ids || version.revision != ordinary_source_revision(version.workspace) { return error('invalid_config_history_version') }
		ids << version.id
	}
	return archive
}

fn config_archive_save(identity string, workspace SharedConfigWorkspace) !string {
	path := config_archive_path(identity)
	safe_recovery_path(path)!
	os.mkdir_all(os.dir(path))!
	if os.stat(os.dir(path))!.uid != u32(os.getuid()) { return error('unsafe_config_history_directory') }
	os.chmod(os.dir(path), 0o700)!
	lease := lock_recovery_archive(path + '.lock')!
	defer { release_recovery_archive(lease) }
	archive := config_archive_read(identity)!
	revision := ordinary_source_revision(workspace)
	for version in archive.versions { if version.revision == revision { return version.id } }
	mut versions := archive.versions.clone()
	id := new_remote_id()!
	versions << McpConfigVersion{id: id, created_at: time.now().format_ss(), revision: revision, workspace: workspace}
	if versions.len > 20 { versions = versions[versions.len - 20..].clone() }
	mut encoded := json.encode(McpConfigArchive{identity: identity, versions: versions})
	for encoded.len > recovery_max_bytes && versions.len > 1 {
		versions = versions[1..].clone()
		encoded = json.encode(McpConfigArchive{identity: identity, versions: versions})
	}
	if encoded.len > recovery_max_bytes { return error('config_history_version_too_large') }
	temp := path + '.' + id + '.tmp'
	defer { os.rm(temp) or {} }
	write_recovery_data(temp, encoded.bytes())!
	safe_recovery_path(path)!
	replace_recovery_data(temp, path)!
	return id
}

fn (s &ServerSession) config_history_root(r McpOrdinaryRelayRequest) !string {
	if r.target_id == '' { return r.access.selection().project.config_path }
	if !s.state.connected { return error('connect_registered_target_host_first') }
	return s.lifecycle_profile(r.target_id)!.config_path
}

fn (s &ServerSession) config_history_versions(r McpOrdinaryRelayRequest, root string) ![]McpConfigVersion {
	mut versions := config_archive_read(s.config_history_identity(r, root))!.versions.clone()
	// Existing Desktop GUI history is readable too; never import an arbitrary
	// path or accept an archive supplied by an Agent.
	if r.target_id == '' {
		mut manager := new_persistent_manager()
		manager.project = r.access.selection().project
		manager.load_recovery_version()!
		for version in manager.recovery_history {
			files := version.sources.map(SharedConfigSource{source: SharedConfigSourcePath{path: it.path}, value: it.value})
			workspace := SharedConfigWorkspace{config_path: root, files: files}
			versions << McpConfigVersion{id: 'desktop-' + version.id, created_at: version.confirmed_at, revision: ordinary_source_revision(workspace), workspace: workspace}
		}
	}
	return versions
}

fn (mut s ServerSession) config_history_list(r McpOrdinaryRelayRequest) !string {
	root := s.config_history_root(r)!
	versions := s.config_history_versions(r, root)!
	mut rows := []map[string]json.Any{}
	for version in versions {
		rows << {'version_id': json.Any(version.id), 'created_at': json.Any(version.created_at), 'source_revision': json.Any(version.revision), 'file_count': json.Any(version.workspace.files.len), 'persisted': json.Any(true), 'origin': json.Any(if version.id.starts_with('desktop-') { 'desktop_history' } else { 'configuration_history' })}
	}
	r.check()!
	return json.encode({'versions': json.Any(rows.map(json.Any(it))), 'retention': json.Any(20), 'scope': json.Any('selected_environment_on_this_desktop')})
}

fn shared_history_changes(current SharedConfigWorkspace, archived SharedConfigWorkspace) ![]OrdinaryConfigChange {
	if current.config_path != archived.config_path || current.files.len != archived.files.len { return error('config_history_source_membership_changed_requires_desktop') }
	mut changes := []OrdinaryConfigChange{}
	for file in current.files {
		targets := archived.files.filter(it.source.path == file.source.path)
		if targets.len != 1 { return error('config_history_source_membership_changed_requires_desktop') }
		if file.value == targets[0].value { continue }
		_ := shared_source_relative(current, file.source.path)!
		if shared_protected_document(file.value)! != shared_protected_document(targets[0].value)! { return error('config_history_protected_changes_require_desktop') }
		changes << OrdinaryConfigChange{path: file.source.path, original: file.value, value: targets[0].value}
	}
	if changes.len == 0 { return error('config_history_already_current') }
	shared_edit_plan_guard(current, changes)!
	return changes
}
