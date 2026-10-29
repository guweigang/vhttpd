module admin_state_store

import os

$if !windows {
fn C.fchmod(int, int) int
fn C.fsync(int) int
}

pub struct ConfigFileChange {
pub:
	path     string
	original string
	value    string
}

// Staged resources remain owned by their publication/restore operation.
struct StagedConfigFile {
	path      string        @[required]
	temporary TemporaryFile @[required]
}

fn (file StagedConfigFile) release() { file.temporary.release() }

fn (file StagedConfigFile) publish(commit fn (string, string) !) ! {
	if !file.temporary.matches() {
		return error('config_staged_file_ownership_changed:' + file.path)
	}
	commit(file.temporary.path, file.path)!
}

fn stage_config_file(path string, value string, mode int) !StagedConfigFile {
	temporary := new_temporary_file(path, 'config.tmp', 0o600)!
	mut ready := false
	defer { if !ready { temporary.release() } }
	write_all(temporary.fd, value)!
	$if windows {
		if C.vh_fsync(temporary.fd) != 0 { return error('config_sync_failed') }
	} $else {
		if C.fchmod(temporary.fd, mode) != 0 { return os.last_error() }
		if C.fsync(temporary.fd) != 0 { return os.last_error() }
	}
	ready = true
	return StagedConfigFile{ path: path, temporary: temporary }
}

fn rename_config_file(source string, target string) ! {
	$if windows {
		if C.vh_rename(source.str, target.str) != 0 { return error('config_replace_failed') }
	} $else {
		if C.rename(&char(source.str), &char(target.str)) != 0 { return os.last_error() }
	}
}

// Content equality does not transfer ownership of a replacement symlink.
// Reuse this guard at admission, publication and compensation boundaries.
fn verify_config_file(path string, expected string) ! {
	if !os.is_file(path) || os.is_link(path) {
		return error('config_changeset_source_not_regular:${path}')
	}
	if os.read_file(path)! != expected {
		return error('config_changeset_source_changed:${path}')
	}
}

// Serialize changeset publishers using the existing store lease. Validate and
// stage every file before touching the originals; compensate committed writes
// on an ordinary write/validation failure. This is not crash recovery.
pub fn (mut store FileStore) publish_config_files(changes []ConfigFileChange, preflight fn () !, postcheck fn () !) ! {
	store.publish_config_files_with(changes, preflight, postcheck, rename_config_file)!
}

fn (mut store FileStore) publish_config_files_with(changes []ConfigFileChange, preflight fn () !, postcheck fn () !, commit fn (string, string) !) ! {
	lease := lock_directory(store.root, true)!
	defer { lease.release() }
	if changes.len == 0 { return error('config_changeset_empty') }
	mut seen := map[string]bool{}
	mut modes := []int{}
	for change in changes {
		verify_config_file(change.path, change.original)!
		physical := os.real_path(change.path)
		if seen[physical] { return error('config_changeset_duplicate_source:${change.path}') }
		seen[physical] = true
		info := os.stat(change.path)!
		modes << int(info.mode & 0o777)
	}
	preflight()!
	mut staged := []StagedConfigFile{}
	defer {
		for file in staged { file.release() }
	}
	for i, change in changes { staged << stage_config_file(change.path, change.value, modes[i])! }
	// Recheck after potentially expensive compilation and staging.
	for change in changes {
		verify_config_file(change.path, change.original)!
	}
	mut committed := 0
	for file in staged {
		file.publish(commit) or {
			rollback_config_files(changes, modes, committed) or { return error('config_changeset_rollback_failed:${err.msg()}') }
			return err
		}
		committed++
	}
	postcheck() or {
		check_error := err
		rollback_config_files(changes, modes, committed) or { return error('config_changeset_rollback_failed:${err.msg()}') }
		return check_error
	}
}

fn rollback_config_files(changes []ConfigFileChange, modes []int, committed int) ! {
	mut failures := []string{}
	for i := committed - 1; i >= 0; i-- {
		change := changes[i]
		verify_config_file(change.path, change.value) or {
			failures << change.path
			continue
		}
		file := stage_config_file(change.path, change.original, modes[i]) or {
			failures << change.path
			continue
		}
		file.publish(rename_config_file) or {
			file.release()
			failures << change.path
			continue
		}
		file.release()
	}
	if failures.len > 0 { return error(failures.join(',')) }
}
