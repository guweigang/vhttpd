module process_runtime

import os
import time

fn C.fcntl(int, int, ...voidptr) int

fn pid_owner_path() string {
	return '/tmp/vhttpd-pid-${os.getpid()}-${time.now().unix_micro()}'
}

fn test_pid_acquisition_deduplicates_shared_listeners_and_is_close_on_exec() {
	path := pid_owner_path()
	mut owner := PidFiles{}
	owner.acquire([path, path]) or { panic(err) }
	owner.acquire([path]) or { panic(err) }
	assert owner.files.len == 1
	file := owner.files[path] or { panic('not owned') }
	assert C.fcntl(file.fd, C.F_GETFD) & C.FD_CLOEXEC != 0
	assert os.read_file(path) or { panic(err) } == '${os.getpid()}'
	owner.close()
	assert !os.exists(path)
	owner.close()
	mut rejected := false
	owner.acquire([path]) or { rejected = true }
	assert rejected
}

fn test_pid_acquisition_preserves_regular_files_and_dangling_symlinks() {
	path := pid_owner_path()
	defer { os.rm(path) or {} }
	mut owner := PidFiles{}
	for content in ['another process', '${os.getpid()}'] {
		os.write_file(path, content) or { panic(err) }
		mut rejected := false
		owner.acquire([path]) or { rejected = true }
		assert rejected
		assert os.read_file(path) or { panic(err) } == content
	}
	os.rm(path) or { panic(err) }
	os.symlink('${path}.missing', path) or { panic(err) }
	mut rejected := false
	owner.acquire([path]) or { rejected = true }
	assert rejected
	owner.close()
	assert (os.lstat(path) or { panic(err) }).get_filetype() == .symbolic_link
	assert !os.exists('${path}.missing')
}

fn test_failed_pid_batch_rolls_back_only_new_files() {
	root := pid_owner_path()
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut owner := PidFiles{}
	owner.acquire([root + '/owned']) or { panic(err) }
	os.write_file(root + '/conflict', 'keep') or { panic(err) }
	mut rejected := false
	owner.acquire([root + '/owned', root + '/new', root + '/conflict']) or { rejected = true }
	assert rejected
	assert os.exists(root + '/owned')
	assert !os.exists(root + '/new')
	assert os.read_file(root + '/conflict') or { panic(err) } == 'keep'
	assert owner.files.len == 1
	owner.close()
	assert !os.exists(root + '/owned')
}

fn test_pid_close_preserves_replacement_even_with_same_pid_text() {
	path := pid_owner_path()
	mut owner := PidFiles{}
	owner.acquire([path]) or { panic(err) }
	os.rm(path) or { panic(err) }
	os.write_file(path, '${os.getpid()}') or { panic(err) }
	defer { os.rm(path) or {} }
	owner.close()
	assert os.read_file(path) or { panic(err) } == '${os.getpid()}'
}

fn test_pid_close_preserves_in_place_content_replacement() {
	path := pid_owner_path()
	mut owner := PidFiles{}
	owner.acquire([path]) or { panic(err) }
	os.write_file(path, 'replacement') or { panic(err) }
	defer { os.rm(path) or {} }
	owner.close()
	assert os.read_file(path) or { panic(err) } == 'replacement'
}

fn test_repeated_pid_close_cannot_remove_or_close_next_generation() {
	path := pid_owner_path()
	mut old := PidFiles{}
	old.acquire([path]) or { panic(err) }
	old.close()
	mut next := PidFiles{}
	next.acquire([path]) or { panic(err) }
	defer { next.close() }
	fd := (next.files[path] or { panic('missing owner') }).fd
	old.close()
	assert C.fcntl(fd, C.F_GETFD) >= 0
	assert os.exists(path)
}

fn pid_compete(mut owner PidFiles, path string, gate chan bool, done chan bool) {
	_ := <-gate
	owner.acquire([path]) or {
		done <- false
		return
	}
	done <- true
}

fn test_independent_pid_owners_compete_without_overwriting_each_other() {
	path := pid_owner_path()
	gate := chan bool{cap: 12}
	done := chan bool{cap: 12}
	mut owners := []&PidFiles{}
	for _ in 0 .. 12 {
		mut owner := &PidFiles{}
		owners << owner
		spawn pid_compete(mut owner, path, gate, done)
	}
	for _ in 0 .. 12 { gate <- true }
	mut winners := 0
	for _ in 0 .. 12 { if <-done { winners++ } }
	assert winners == 1
	for mut owner in owners { owner.close() }
	assert !os.exists(path)
}

fn test_pid_close_linearizes_with_concurrent_acquisition() {
	path := pid_owner_path()
	mut owner := &PidFiles{}
	gate := chan bool{cap: 2}
	done := chan bool{cap: 2}
	spawn pid_compete(mut owner, path, gate, done)
	spawn fn [mut owner, gate, done] () {
		_ := <-gate
		owner.close()
		done <- true
	}()
	gate <- true
	gate <- true
	_ := <-done
	_ := <-done
	assert owner.closed
	assert owner.files.len == 0
	assert !os.exists(path)
}

fn test_pid_reacquire_detects_replacement_and_rolls_back_new_candidate() {
	path := pid_owner_path()
	mut owner := PidFiles{}
	owner.acquire([path]) or { panic(err) }
	os.write_file(path, 'changed') or { panic(err) }
	defer { os.rm(path) or {} }
	mut rejected := false
	owner.acquire(['${path}.new', path]) or { rejected = true }
	assert rejected
	assert !os.exists('${path}.new')
	owner.close()
	assert os.read_file(path) or { panic(err) } == 'changed'
}
