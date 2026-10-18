module admin_state_store

import os
import rand
import time

fn C.fcntl(int, int, ...voidptr) int

fn lock_admission_root() string {
	root := os.join_path(os.real_path(os.temp_dir()), 'lock-admission-' + rand.uuid_v4())
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn lock_admission_waiter(root string, exclusive bool, done chan string) {
	lease := lock_directory(root, exclusive) or {
		done <- err.msg()
		return
	}
	lease.release()
	done <- 'admitted'
}

// Identify the waiter's open fd before replacing the directory entry. The
// original lease remains held, so admission cannot happen before replacement.
fn wait_for_old_lock_descriptor(original int, identity os.Stat) int {
	deadline := time.now().add(5 * time.second)
	for time.now() < deadline {
		for fd in 0 .. 1024 {
			if fd == original { continue }
			mut native := C.stat{}
			if C.fstat(fd, &native) == 0 && u64(native.st_dev) == identity.dev && u64(native.st_ino) == identity.inode {
				return fd
			}
		}
		time.sleep(time.millisecond)
	}
	panic('waiter did not open the original lock inode')
}

fn check_lock_admission_replacement(link bool, exclusive bool) {
	root := lock_admission_root()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, '.vhttpd.lock')
	moved := os.join_path(root, 'retired-lock')
	original := lock_directory(root, true) or { panic(err) }
	mut original_released := false
	defer { if !original_released { original.release() } }
	identity := os.lstat(path) or { panic(err) }
	done := chan string{cap: 1}
	spawn lock_admission_waiter(root, exclusive, done)
	waiter := wait_for_old_lock_descriptor(original.fd, identity)
	assert C.fcntl(waiter, C.F_GETFD) & C.FD_CLOEXEC != 0
	rename_config_file(path, moved) or { panic(err) }
	if link {
		os.symlink(moved, path) or { panic(err) }
	} else {
		os.write_file(path, 'replacement') or { panic(err) }
	}
	// Hold the replacement inode's lock while the old waiter is unblocked.
	// A regular replacement would allow a second writer to enter concurrently.
	if !link {
		replacement := lock_directory(root, true) or { panic(err) }
		mut replacement_released := false
		defer { if !replacement_released { replacement.release() } }
		original_released = true
		original.release()
		mut outcome := ''
		select {
			result := <-done {
				outcome = result
			}
			5 * time.second {
				panic('waiter failed to reject the retired lock inode')
			}
		}
		closed := C.fcntl(waiter, C.F_GETFD) == -1
		replacement_released = true
		replacement.release()
		assert outcome == 'admin_state_store_lock_ownership_changed'
		assert closed
		assert os.read_file(path) or { panic(err) } == 'replacement'
		usable := lock_directory(root, false) or { panic(err) }
		usable.release()
	} else {
		original_released = true
		original.release()
		mut outcome := ''
		select {
			result := <-done {
				outcome = result
			}
			5 * time.second {
				panic('waiter failed to reject the replacement symlink')
			}
		}
		assert outcome == 'admin_state_store_lock_ownership_changed'
		assert C.fcntl(waiter, C.F_GETFD) == -1
		assert os.is_link(path)
	}
	assert os.exists(moved)
}

fn test_exclusive_waiter_rejects_replaced_lock_inode() {
	check_lock_admission_replacement(false, true)
}

fn test_shared_waiter_rejects_replaced_lock_inode() {
	check_lock_admission_replacement(false, false)
}

fn test_exclusive_waiter_rejects_symlink_to_retired_lock_inode() {
	check_lock_admission_replacement(true, true)
}

fn test_shared_waiter_rejects_symlink_to_retired_lock_inode() {
	check_lock_admission_replacement(true, false)
}
