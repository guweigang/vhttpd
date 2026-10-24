module logging

import os
import time

fn C.fcntl(i32, i32, ...voidptr) i32

fn log_test_root() string {
	root := os.join_path(os.temp_dir(), 'vhttpd-log-owner-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(root) or { panic(err) }
	return root
}

fn test_log_append_excludes_live_fd_from_exec_and_closes_after_write() {
	root := log_test_root()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'events')
	seen := chan int{cap: 1}
	append_line_with(path, 'record', fn [seen] (fd int, data string) ! {
		seen <- fd
		control := C.fcntl(i32(fd), C.F_DUPFD, 0)
		assert control >= 0
		defer { C.close(control) }
		mut child := os.new_process(os.find_abs_path_of_executable('test') or { panic(err) })
		defer { child.close() }
		// The deliberately inheritable control must survive the same exec.
		child.set_args(['-f', '/dev/fd/${control}', '-a', '!', '-f', '/dev/fd/${fd}'])
		child.run()
		assert child.pid > 0
		child.wait()
		assert child.code == 0
		assert C.fcntl(i32(fd), C.F_GETFD, 0) & C.FD_CLOEXEC != 0
		write_log_bytes(fd, data)!
	}) or { panic(err) }
	fd := <-seen
	assert C.fcntl(i32(fd), C.F_GETFD, 0) < 0
	assert os.read_file(path) or { panic(err) } == 'record\n'
}

fn test_log_writer_failure_closes_fd_and_next_append_succeeds() {
	root := log_test_root()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'events')
	seen := chan int{cap: 1}
	mut failed := false
	append_line_with(path, 'rejected', fn [seen] (fd int, _ string) ! {
		seen <- fd
		return error('writer_failed')
	}) or {
		failed = true
		assert err.msg() == 'writer_failed'
	}
	assert failed
	fd := <-seen
	assert C.fcntl(i32(fd), C.F_GETFD, 0) < 0
	append_line(path, 'next') or { panic(err) }
	assert os.read_file(path) or { panic(err) } == 'next\n'
}

fn test_log_append_preserves_existing_bytes_unicode_and_empty_record() {
	root := log_test_root()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'events')
	os.write_file(path, 'existing\n') or { panic(err) }
	append_line(path, '日志') or { panic(err) }
	append_line(path, '') or { panic(err) }
	assert os.read_file(path) or { panic(err) } == 'existing\n日志\n\n'
}

fn test_log_open_failure_does_not_create_parent_or_truncated_path() {
	root := log_test_root()
	defer { os.rmdir_all(root) or {} }
	for path in [os.join_path(root, 'missing/events'), os.join_path(root, 'events') + '\x00suffix'] {
		mut failed := false
		append_line(path, 'record') or { failed = true }
		assert failed
	}
	assert os.ls(root) or { panic(err) } == []string{}
}

fn append_log_records(path string, idx int, done chan bool) {
	for n in 0 .. 16 { append_line(path, '${idx}/${n}') or { panic(err) } }
	done <- true
}

fn test_concurrent_log_appends_own_independent_descriptors() {
	root := log_test_root()
	defer { os.rmdir_all(root) or {} }
	path := os.join_path(root, 'events')
	done := chan bool{cap: 8}
	for i in 0 .. 8 { spawn append_log_records(path, i, done) }
	for _ in 0 .. 8 { _ := <-done }
	lines := os.read_lines(path) or { panic(err) }
	assert lines.len == 128
	mut seen := map[string]bool{}
	for line in lines { seen[line] = true }
	for i in 0 .. 8 {
		for n in 0 .. 16 {
			assert seen['${i}/${n}']
		}
	}
}
