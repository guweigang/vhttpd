module admin_state_store

import os

#include <sys/stat.h>

fn C.fstat(int, &C.stat) int

// Separate from publication: recovery may recreate a missing, previously trusted source.
pub struct ConfigFileRestore {
pub:
	path            string
	original        string
	original_exists bool
	value           string
	mode            int = 0o600
}

fn verify_restore_source(change ConfigFileRestore) ! {
	mut parent := os.dir(os.abs_path(change.path))
	for {
		if os.is_link(parent) { return error('config_restore_symlink_parent:${parent}') }
		next := os.dir(parent)
		if parent == next { break }
		parent = next
	}
	if os.is_link(change.path) { return error('config_restore_symlink:${change.path}') }
	if change.original_exists {
		if !os.is_file(change.path) || os.read_file(change.path)! != change.original {
			return error('config_restore_source_changed:${change.path}')
		}
	} else if os.exists(change.path) {
		return error('config_restore_source_created:${change.path}')
	}
}

// Operation-local cleanup authority. Retain the inode until cleanup decides
// whether the pathname still belongs to this restore attempt.
struct CreatedConfigDirectory {
	path     string  @[required]
	identity os.Stat @[required]
	fd       int     @[required]
}

fn (directory CreatedConfigDirectory) matches() bool {
	current := os.lstat(directory.path) or { return false }
	return current.get_filetype() == .directory && current.dev == directory.identity.dev && current.inode == directory.identity.inode
}

fn (directory CreatedConfigDirectory) release() {
	defer { C.close(directory.fd) }
	if directory.matches() { os.rmdir(directory.path) or {} }
}

fn retain_created_config_directory(path string, identity os.Stat) !CreatedConfigDirectory {
	fd := C.open(&char(path.str), C.O_RDONLY | C.O_DIRECTORY | C.O_NOFOLLOW | C.O_CLOEXEC)
	if fd < 0 { return os.last_error() }
	mut native := C.stat{}
	for C.fstat(fd, &native) != 0 {
		if C.errno == C.EINTR { continue }
		failure := os.last_error()
		C.close(fd)
		return failure
	}
	owned := CreatedConfigDirectory{ path: path, identity: identity, fd: fd }
	if u64(native.st_dev) != identity.dev || u64(native.st_ino) != identity.inode || !owned.matches() {
		C.close(fd)
		return error('config_restore_directory_changed:' + path)
	}
	return owned
}

fn restore_parent_dirs(path string, mut created []CreatedConfigDirectory) ! {
	mut missing := []string{}
	mut parent := os.dir(path)
	for !os.exists(parent) {
		missing << parent
		next := os.dir(parent)
		if next == parent { return error('config_restore_parent_missing') }
		parent = next
	}
	for i := missing.len - 1; i >= 0; i-- {
		os.mkdir(missing[i], mode: 0o700)!
		identity := os.lstat(missing[i])!
		owned := retain_created_config_directory(missing[i], identity) or {
			// No retained descriptor is available on failure; remove only a verified
			// directory entry, rather than acquiring a replacement by its name.
			current := os.lstat(missing[i]) or { return err }
			if current.get_filetype() == .directory && current.dev == identity.dev && current.inode == identity.inode {
				os.rmdir(missing[i]) or {}
			}
			return err
		}
		created << owned
		if C.fchmod(owned.fd, 0o700) != 0 { return os.last_error() }
	}
}

// Uses the same lease as Admin publication, stages the full set and compensates
// ordinary failures. No cross-file crash recovery is promised.
pub fn (mut store FileStore) restore_config_files(changes []ConfigFileRestore, preflight fn () !, postcheck fn () !) ! {
	store.restore_config_files_with(changes, preflight, postcheck, rename_config_file)!
}

fn (mut store FileStore) restore_config_files_with(changes []ConfigFileRestore, preflight fn () !, postcheck fn () !, commit fn (string, string) !) ! {
	lease := lock_directory(store.root, true)!
	defer { lease.release() }
	if changes.len == 0 { return error('config_restore_empty') }
	mut paths := map[string]bool{}
	mut modes := []int{}
	for change in changes {
		verify_restore_source(change)!
		path := os.abs_path(change.path)
		if paths[path] { return error('config_restore_duplicate_source') }
		paths[path] = true
		modes << if change.original_exists { int(os.stat(path)!.mode & 0o777) } else { 0 }
	}
	preflight()!
	mut staged := []StagedConfigFile{}
	mut dirs := []CreatedConfigDirectory{}
	defer {
		for file in staged { file.release() }
		for i := dirs.len - 1; i >= 0; i-- { dirs[i].release() }
	}
	for change in changes {
		restore_parent_dirs(change.path, mut dirs)!
		staged << stage_config_file(change.path, change.value, change.mode & 0o777)!
	}
	for change in changes { verify_restore_source(change)! }
	mut committed := 0
	for file in staged {
		file.publish(commit) or {
			restore_compensate(changes, modes, committed) or { return error('config_restore_compensation_failed') }
			return err
		}
		committed++
	}
	postcheck() or {
		failure := err
		restore_compensate(changes, modes, committed) or { return error('config_restore_compensation_failed') }
		return failure
	}
}

fn restore_compensate(changes []ConfigFileRestore, modes []int, committed int) ! {
	mut failed := false
	for i := committed - 1; i >= 0; i-- {
		change := changes[i]
		current := os.read_file(change.path) or {
			failed = true
			continue
		}
		if os.is_link(change.path) || current != change.value {
			failed = true
			continue
		}
		if !change.original_exists {
			os.rm(change.path) or { failed = true }
			continue
		}
		file := stage_config_file(change.path, change.original, modes[i]) or {
			failed = true
			continue
		}
		file.publish(rename_config_file) or {
			file.release()
			failed = true
			continue
		}
		file.release()
	}
	if failed { return error('config_restore_compensation_failed') }
}
