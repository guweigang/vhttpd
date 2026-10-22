module admin_state_store

import os
import time

fn create_store_for_first_request(root string, result chan bool) {
	_ := FileStore.new(root) or { result <- false; return }
	result <- true
}

fn test_concurrent_first_requests_share_new_state_directory() ! {
	base := os.join_path(os.temp_dir(), 'admin-first-load-${os.getpid()}-${time.now().unix_micro()}')
	defer { os.rmdir_all(base) or {} }
	for i in 0 .. 12 {
		root := os.join_path(base, i.str(), 'project', 'admin')
		result := chan bool{cap: 16}
		for _ in 0 .. 16 { spawn create_store_for_first_request(root, result) }
		for _ in 0 .. 16 { assert <-result }
		assert os.is_dir(root)
	}
}

fn test_existing_file_is_not_accepted_as_a_state_directory() ! {
	path := os.join_path(os.temp_dir(), 'admin-first-load-file-${os.getpid()}-${time.now().unix_micro()}')
	os.write_file(path, 'keep')!
	defer { os.rm(path) or {} }
	if _ := FileStore.new(path) { assert false, 'A regular file cannot be a state directory' }
	assert os.read_file(path)! == 'keep'
}
