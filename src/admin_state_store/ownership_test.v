module admin_state_store

import os
import time

fn C.fcntl(int, int, ...voidptr) int

fn store_owner_root(name string) string {
	return os.join_path(os.temp_dir(), '${name}_${os.getpid()}_${time.now().unix_micro()}')
}

fn testsuite_begin() {
	if os.args.len == 3 && os.args[1] == '--store-lock-child' {
		lease := lock_directory(os.args[2], true) or { panic(err) }
		os.write_file(os.join_path(os.args[2], 'ready'), 'locked') or { panic(err) }
		for { time.sleep(time.second) }
		lease.release()
		exit(0)
	}
}

fn store_operation(root string, operation string, entered chan bool, done chan string) {
	mut store := FileStore.new(root) or { panic(err) }
	entered <- true
	match operation {
		'get' {
			store.get('drafts', 'key') or {
				done <- err.msg()
				return
			}
		}
		'list' {
			store.list('drafts') or {
				done <- err.msg()
				return
			}
		}
		'events' {
			store.list_events(0) or {
				done <- err.msg()
				return
			}
		}
		'put' {
			store.put('drafts', 'key', 'new') or {
				done <- err.msg()
				return
			}
		}
		'delete' {
			store.delete('drafts', 'key') or {
				done <- err.msg()
				return
			}
		}
		'append' {
			store.append_event('changed', {}) or {
				done <- err.msg()
				return
			}
		}
		else { panic(operation) }
	}
	done <- 'ok'
}

fn assert_store_blocked(done chan string) {
	select {
		result := <-done {
			panic('operation escaped its directory lease: ${result}')
		}
		150 * time.millisecond {
		}
	}
}

fn await_store_operation(done chan string) {
	select {
		result := <-done {
			assert result == 'ok'
		}
		5 * time.second {
			panic('operation did not release its directory lease')
		}
	}
}

fn test_independent_request_stores_share_read_and_write_boundary() {
	root := store_owner_root('vhttpd_store_boundary')
	defer { os.rmdir_all(root) or {} }
	mut original := FileStore.new(root) or { panic(err) }
	for operation in ['get', 'list', 'events', 'put', 'delete', 'append'] {
		original.put('drafts', 'key', 'old') or { panic(err) }
		lease := lock_directory(root, true) or { panic(err) }
		assert C.fcntl(lease.fd, C.F_GETFD) & C.FD_CLOEXEC != 0
		entered := chan bool{cap: 1}
		done := chan string{cap: 1}
		spawn store_operation(root, operation, entered, done)
		_ := <-entered
		assert_store_blocked(done)
		lease.release()
		await_store_operation(done)
		assert os.exists(os.join_path(root, '.vhttpd.lock'))
	}
}

fn test_event_reader_waits_for_in_flight_append_to_finish() {
	root := store_owner_root('vhttpd_store_partial_event')
	defer { os.rmdir_all(root) or {} }
	mut store := FileStore.new(root) or { panic(err) }
	lease := lock_directory(root, true) or { panic(err) }
	os.write_file(store.events_path(), '{"id":') or { panic(err) }
	entered := chan bool{cap: 1}
	done := chan string{cap: 1}
	spawn store_operation(root, 'events', entered, done)
	_ := <-entered
	assert_store_blocked(done)
	os.write_file(store.events_path(), '{"id":"complete","type":"changed","fields":{}}\n') or { panic(err) }
	lease.release()
	await_store_operation(done)
	events := store.list_events(0) or { panic(err) }
	assert events.len == 1
	assert events[0].id == 'complete'
}

fn append_store_payload(root string, id int, done chan string) {
	mut store := FileStore.new(root) or { panic(err) }
	for i in 0 .. 8 {
		store.append_event('concurrent', {
			'writer':  '${id}'
			'index':   '${i}'
			'payload': '${id}'.repeat(100000)
		}) or {
			done <- err.msg()
			return
		}
	}
	done <- 'ok'
}

fn test_large_events_from_independent_stores_remain_complete() {
	root := store_owner_root('vhttpd_store_concurrent_events')
	defer { os.rmdir_all(root) or {} }
	mut store := FileStore.new(root) or { panic(err) }
	done := chan string{cap: 4}
	for id in 0 .. 4 { spawn append_store_payload(root, id, done) }
	for _ in 0 .. 4 { await_store_operation(done) }
	events := store.list_events(0) or { panic(err) }
	assert events.len == 32
	mut seen := map[string]bool{}
	for event in events {
		assert event.fields['payload'] == event.fields['writer'].repeat(100000)
		seen['${event.fields['writer']}:${event.fields['index']}'] = true
	}
	assert seen.len == 32
}

fn test_atomic_write_rejects_directory_destination_without_leaking_temporary_file() {
	root := store_owner_root('vhttpd_store_rename_failure')
	defer { os.rmdir_all(root) or {} }
	mut store := FileStore.new(root) or { panic(err) }
	path := store.entry_path('drafts', 'key')
	os.mkdir_all(path) or { panic(err) }
	os.write_file(os.join_path(path, 'keep'), 'original') or { panic(err) }
	mut failed := false
	store.put('drafts', 'key', 'replacement') or { failed = true }
	assert failed
	assert os.ls(os.dir(path)) or { panic(err) } == ['key.json']
	assert os.ls(path) or { panic(err) } == ['keep']
	assert os.read_file(os.join_path(path, 'keep')) or { panic(err) } == 'original'
	// A failed mutation must also release its directory lease.
	store.put('drafts', 'next', 'usable') or { panic(err) }
}

fn fail_after_partial_write(fd int, value string) ! {
	assert C.fcntl(fd, C.F_GETFD) & C.FD_CLOEXEC != 0
	write_all(fd, value[..value.len / 2])!
	return error_with_code('injected_partial_write', fd)
}

fn test_atomic_write_failure_preserves_previous_value_and_closes_owned_fd() {
	root := store_owner_root('vhttpd_store_write_failure')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'key.json')
	os.write_file(path, 'old') or { panic(err) }
	mut failed := false
	atomic_write_with(path, 'replacement', fail_after_partial_write) or {
		failed = true
		assert err.msg() == 'injected_partial_write'
		assert C.fcntl(err.code(), C.F_GETFD) == -1
	}
	assert failed
	assert os.read_file(path) or { panic(err) } == 'old'
	assert os.ls(root) or { panic(err) } == ['key.json']
}

fn test_failed_event_append_rolls_back_only_its_tail_and_closes_owned_fd() {
	root := store_owner_root('vhttpd_store_append_failure')
	defer { os.rmdir_all(root) or {} }
	mut store := FileStore.new(root) or { panic(err) }
	store.append_event('original', {}) or { panic(err) }
	before := os.read_file(store.events_path()) or { panic(err) }
	lease := lock_directory(root, true) or { panic(err) }
	mut failed := false
	append_line_with(store.events_path(), '{"id":"broken"}', fail_after_partial_write) or {
		failed = true
		assert err.msg() == 'injected_partial_write'
		assert C.fcntl(err.code(), C.F_GETFD) == -1
	}
	lease.release()
	assert failed
	assert os.read_file(store.events_path()) or { panic(err) } == before
	store.append_event('next', {}) or { panic(err) }
	assert (store.list_events(0) or { panic(err) }).map(it.type_) == ['original', 'next']
}

fn test_process_exit_releases_directory_lease_for_other_request_stores() {
	root := store_owner_root('vhttpd_store_process_lock')
	FileStore.new(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut child := os.new_process(os.executable())
	child.set_args(['--store-lock-child', root])
	child.run()
	defer {
		child.signal_kill()
		child.wait()
		child.close()
	}
	deadline := time.now().add(5 * time.second)
	for !os.exists(os.join_path(root, 'ready')) {
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	entered := chan bool{cap: 1}
	done := chan string{cap: 1}
	spawn store_operation(root, 'put', entered, done)
	_ := <-entered
	assert_store_blocked(done)
	child.signal_kill()
	child.wait()
	await_store_operation(done)
	mut store := FileStore.new(root) or { panic(err) }
	assert (store.get('drafts', 'key') or { panic(err) }).value == 'new'
}
