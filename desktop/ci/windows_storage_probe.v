module main

import os
import admin_state_store
import process_runtime
import windows_files

fn C.vh_handle(int) voidptr
fn C.GetHandleInformation(voidptr, &u32) i32

fn accept() ! {}

fn reject() ! { return error('intentional_postcheck_failure') }

fn main() {
	root := os.join_path(os.temp_dir(), 'vhttpd Windows 验收 ${os.getpid()}')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	lock_path := os.join_path(root, 'lock')
	first := C.vh_open(lock_path.str, C.VH_O_RDWR | C.VH_O_CREAT, 0o600)
	second := C.vh_open(lock_path.str, C.VH_O_RDWR | C.VH_O_CREAT, 0o600)
	assert first >= 0 && second >= 0
	mut handle_flags := u32(0)
	assert C.GetHandleInformation(C.vh_handle(first), &handle_flags) != 0
	assert handle_flags & 1 == 0
	assert C.vh_flock(first, C.VH_LOCK_SH) == 0
	assert C.vh_flock(second, C.VH_LOCK_SH | C.VH_LOCK_NB) == 0
	assert C.vh_flock(second, C.VH_LOCK_UN) == 0
	assert C.vh_flock(second, C.VH_LOCK_EX | C.VH_LOCK_NB) != 0
	assert C.vh_close(first) == 0
	assert C.vh_flock(second, C.VH_LOCK_EX | C.VH_LOCK_NB) == 0
	assert C.vh_close(second) == 0
	mut store := admin_state_store.FileStore.new(os.join_path(root, 'state'))!
	store.put('config', 'one', 'first')!
	store.put('config', 'one', 'replacement')!
	assert store.get('config', 'one')!.value == 'replacement'
	a := os.join_path(root, 'main.toml')
	b := os.join_path(root, 'include 配置.toml')
	os.write_file(a, 'old a')!
	os.write_file(b, 'old b')!
	changes := [
		admin_state_store.ConfigFileChange{ path: a, original: 'old a', value: 'new a' },
		admin_state_store.ConfigFileChange{ path: b, original: 'old b', value: 'new b' },
	]
	mut failed := false
	store.publish_config_files(changes, accept, reject) or {
 failed = true
 eprintln('Windows publication probe: ' + err.msg())
 assert err.msg() == 'intentional_postcheck_failure'
 }
	assert failed
	assert os.read_file(a)! == 'old a'
	assert os.read_file(b)! == 'old b'
	store.publish_config_files(changes, accept, accept)!
	assert os.read_file(a)! == 'new a'
	assert os.read_file(b)! == 'new b'
	nested := os.join_path(root, '恢复目录', 'include', 'relay.toml')
	restores := [admin_state_store.ConfigFileRestore{ path: nested, original_exists: false, value: 'restored include' }]
	mut restore_failed := false
	store.restore_config_files(restores, accept, reject) or { restore_failed = true }
	assert restore_failed
	assert !os.exists(os.join_path(root, '恢复目录'))
	store.restore_config_files(restores, accept, accept)!
	assert os.read_file(nested)! == 'restored include'

	// Retained file identity must never authorize deleting a replacement entry.
	owned := os.join_path(root, 'owned')
	fd := C.vh_open(owned.str, C.VH_O_WRONLY | C.VH_O_CREAT | C.VH_O_EXCL, 0o600)
	assert fd >= 0
	dev := C.vh_dev(fd)
	ino := C.vh_ino(fd)
	retired := os.join_path(root, 'retired')
	assert C.vh_rename(owned.str, root.str) != 0
	assert os.is_file(owned)
	assert C.vh_rename(owned.str, retired.str) == 0
	os.write_file(owned, 'other owner')!
	assert C.vh_matches(owned.str, dev, ino) == 0
	C.vh_remove_owned(fd, owned.str, dev, ino)
	C.vh_close(fd)
	assert os.read_file(owned)! == 'other owner'
	mut owner := process_runtime.PidFiles{}
	pid_path := os.join_path(root, 'runtime.pid')
	owner.acquire([pid_path])!
	assert os.read_file(pid_path)! == '${os.getpid()}'
	owner.close()
	assert !os.exists(pid_path)
	println('PASS Windows Unicode paths, shared/exclusive locks, atomic replacement, cross-include compensation, file identity and PID cleanup')
}
