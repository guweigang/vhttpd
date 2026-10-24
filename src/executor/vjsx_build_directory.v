module executor

import crypto.rand as crypto_rand
import os
import sync

// Every copy of a host retains the same cleanup authority. A string path or
// cache prefix alone never authorizes another host's directory to be removed.
@[heap]
struct VjsxBuildDirectory {
	path     string  @[required]
	identity os.Stat @[required]
	fd       int     @[required]
mut:
	mu       sync.Mutex
	released bool
}

fn VjsxBuildDirectory.reserve(prefix string) !&VjsxBuildDirectory {
	os.mkdir_all(os.dir(prefix))!
	for _ in 0 .. 8 {
		// The OS random source is safe across concurrent constructors. mkdir is the
		// exclusive admission boundary even if names collide with existing entries.
		suffix := (crypto_rand.bytes(16)!).hex()
		path := '${prefix}.owned_${suffix}'
		os.mkdir(path, mode: 0o700) or {
			if os.exists(path) { continue }
			return err
		}
		identity := os.lstat(path)!
		fd := retain_build_directory(path, identity) or {
			if owns_build_directory(path, identity) { os.rmdir(path) or {} }
			return err
		}
		return &VjsxBuildDirectory{ path: path, identity: identity, fd: fd }
	}
	return error('inproc_vjsx_executor_build_directory_exhausted')
}

fn (directory VjsxBuildDirectory) output_path() string {
	return os.join_path(directory.path, 'output')
}

fn owns_build_directory(path string, identity os.Stat) bool {
	current := os.lstat(path) or { return false }
	return current.get_filetype() == .directory && current.dev == identity.dev
		&& current.inode == identity.inode
}

fn (mut directory VjsxBuildDirectory) release() {
	directory.mu.@lock()
	defer { directory.mu.unlock() }
	if directory.released { return }
	if owns_build_directory(directory.path, directory.identity) {
		os.rmdir_all(directory.path) or {
			// Retain cleanup authority and the inode while a retry is needed.
			if owns_build_directory(directory.path, directory.identity) { return }
		}
	}
	// A moved/replaced path is no longer ours to remove. Retire this owner and
	// release its inode even when the original tree now has another pathname.
	directory.released = true
	close_build_directory(directory.fd)
}
