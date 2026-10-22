module connection_runtime

import listener_runtime
import net
import net.unix
import os
import time

fn dial_fd_count() int { return (os.ls('/dev/fd') or { panic(err) }).len }

fn dial_fixture_path() string {
	return '/tmp/vhttpd-unix-dial-${os.getpid()}-${time.sys_mono_now()}.sock'
}

fn dial_expect_failure(path string) {
	if mut conn := dial_unix(path) {
		conn.close() or {}
		panic('unexpected Unix connection')
	}
}

fn test_missing_unix_dials_release_every_failed_candidate() {
	path := dial_fixture_path()
	dial_expect_failure(path)
	before := dial_fd_count()
	for _ in 0 .. 128 { dial_expect_failure(path) }
	assert dial_fd_count() == before
}

fn test_refused_and_regular_file_dials_release_candidates_and_preserve_paths() {
	path := dial_fixture_path()
	mut listener := unix.listen_stream(path) or { panic(err) }
	// Model a crashed listener: close its fd without unlinking the socket entry.
	// Do not call close() on this stale wrapper after its fd becomes reusable.
	net.close(listener.sock.handle) or { panic(err) }
	defer { os.rm(path) or {} }
	file := '${path}.file'
	os.write_file(file, 'keep') or { panic(err) }
	defer { os.rm(file) or {} }
	before := dial_fd_count()
	for _ in 0 .. 32 {
		dial_expect_failure(path)
		dial_expect_failure(file)
	}
	assert dial_fd_count() == before
	assert os.exists(path)
	assert os.read_file(file) or { panic(err) } == 'keep'
}

fn test_invalid_unix_dial_paths_do_not_allocate_fds_or_truncate_destination() {
	path := dial_fixture_path()
	mut listener := listener_runtime.listen(path) or { panic(err) }
	defer { listener.close() or {} }
	before := dial_fd_count()
	for _ in 0 .. 16 {
		for invalid in ['', '${path}\x00suffix', '/tmp/' + 'x'.repeat(99)] {
			dial_expect_failure(invalid)
		}
	}
	assert dial_fd_count() == before
}

fn dial_exchange(path string, check_child bool) {
	mut listener := listener_runtime.listen(path) or { panic(err) }
	defer { listener.close() or {} }
	mut conn := dial_unix(path) or { panic(err) }
	defer { conn.close() or {} }
	mut peer := listener.accept() or { panic(err) }
	defer { peer.close() or {} }
	assert conn.read_timeout() == 30 * time.second
	assert conn.write_timeout() == 30 * time.second
	assert C.fcntl(i32(conn.sock.handle), C.F_GETFD) & C.FD_CLOEXEC != 0
	if check_child {
		executable := os.find_abs_path_of_executable('test') or { panic(err) }
		mut child := os.new_process(executable)
		defer { child.close() }
		child.set_args(['-S', '/dev/fd/${conn.sock.handle}'])
		child.run()
		assert child.pid > 0
		child.wait()
		assert child.code == 1
	}
	conn.write_string('request') or { panic(err) }
	mut request := []u8{len: 7}
	assert peer.read(mut request) or { panic(err) } == 7
	assert request.bytestr() == 'request'
	peer.write_string('response') or { panic(err) }
	mut response := []u8{len: 8}
	assert conn.read(mut response) or { panic(err) } == 8
	assert response.bytestr() == 'response'
}

fn test_connected_unix_handle_transfers_io_and_excludes_exec_children() {
	before := dial_fd_count()
	dial_exchange(dial_fixture_path(), true)
	assert dial_fd_count() == before
}

fn test_concurrent_failed_unix_dials_release_only_their_own_candidates() {
	path := dial_fixture_path()
	before := dial_fd_count()
	mut jobs := []thread{}
	for _ in 0 .. 8 {
		jobs << spawn fn [path] () {
			for _ in 0 .. 32 { dial_expect_failure(path) }
		}()
	}
	jobs.wait()
	assert dial_fd_count() == before
}

fn test_unix_dial_recovers_when_failed_destination_becomes_ready() {
	path := dial_fixture_path()
	before := dial_fd_count()
	for _ in 0 .. 8 { dial_expect_failure(path) }
	dial_exchange(path, false)
	assert dial_fd_count() == before
}

fn test_repeated_successful_unix_dials_release_handed_off_connections() {
	before := dial_fd_count()
	for _ in 0 .. 16 { dial_exchange(dial_fixture_path(), false) }
	assert dial_fd_count() == before
}
