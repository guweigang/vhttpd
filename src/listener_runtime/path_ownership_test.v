module listener_runtime

import net
import net.unix
import os
import time

fn path_owner_fixture() string {
	return '/tmp/vhttpd-path-${os.getpid()}-${time.now().unix_micro()}.sock'
}

fn test_existing_live_socket_is_not_replaced_by_second_listener() {
	path := path_owner_fixture()
	mut first := listen(path) or { panic(err) }
	defer { first.close() or {} }
	before := os.lstat(path) or { panic(err) }
	if mut unexpected := listen(path) {
		unexpected.close() or {}
		assert false, 'second bind replaced the active listener'
	}
	assert (os.lstat(path) or { panic(err) }).inode == before.inode
	mut peer := unix.connect_stream(path) or { panic(err) }
	defer { peer.close() or {} }
	mut accepted := first.accept() or { panic(err) }
	accepted.close() or { panic(err) }
}

fn test_existing_regular_file_and_dangling_symlink_are_preserved() {
	path := path_owner_fixture()
	defer {
		os.rm(path) or {}
		os.rm('${path}.missing') or {}
	}
	os.write_file(path, 'keep') or { panic(err) }
	if mut unexpected := listen(path) {
		unexpected.close() or {}
		assert false
	}
	assert os.read_file(path) or { panic(err) } == 'keep'
	os.rm(path) or { panic(err) }
	os.symlink('${path}.missing', path) or { panic(err) }
	before := os.lstat(path) or { panic(err) }
	if mut unexpected := listen(path) {
		unexpected.close() or {}
		assert false
	}
	after := os.lstat(path) or { panic(err) }
	assert after.get_filetype() == .symbolic_link
	assert after.inode == before.inode
}

fn test_close_preserves_replacement_socket_and_is_idempotent() {
	path := path_owner_fixture()
	mut old := listen(path) or { panic(err) }
	os.rm(path) or { panic(err) }
	mut replacement := listen(path) or { panic(err) }
	defer { replacement.close() or {} }
	old.close() or { panic(err) }
	old.close() or { panic(err) }
	mut peer := unix.connect_stream(path) or { panic(err) }
	defer { peer.close() or {} }
	mut accepted := replacement.accept() or { panic(err) }
	accepted.close() or { panic(err) }
}

fn test_owner_finish_preserves_replacement_file() {
	path := path_owner_fixture()
	mut owner := Owner{}
	generation := owner.reserve() or { panic('reservation') }
	listener := listen(path) or { panic(err) }
	assert owner.publish(generation, listener)
	os.rm(path) or { panic(err) }
	os.write_file(path, 'replacement') or { panic(err) }
	defer { os.rm(path) or {} }
	assert owner.finish(generation)
	assert os.read_file(path) or { panic(err) } == 'replacement'
}

struct PathAttempt {
	listener ?&Listener
}

fn race_path_listener(path string, gate chan bool, results chan PathAttempt) {
	_ := <-gate
	listener := listen(path) or {
		results <- PathAttempt{}
		return
	}
	results <- PathAttempt{ listener: listener }
}

fn test_independent_concurrent_owners_have_one_bind_winner() {
	path := path_owner_fixture()
	gate := chan bool{cap: 12}
	results := chan PathAttempt{cap: 12}
	for _ in 0 .. 12 { spawn race_path_listener(path, gate, results) }
	for _ in 0 .. 12 { gate <- true }
	mut winners := []&Listener{}
	for _ in 0 .. 12 {
		result := <-results
		if listener := result.listener { winners << listener }
	}
	defer {
		for mut winner in winners { winner.close() or {} }
	}
	assert winners.len == 1
	mut peer := unix.connect_stream(path) or { panic(err) }
	peer.close() or { panic(err) }
}

fn test_stale_socket_is_preserved_and_invalid_paths_are_rejected() {
	path := path_owner_fixture()
	mut stale := listen(path) or { panic(err) }
	// Simulate a crashed process that closed its fd without unlinking.
	net.close(stale.native.sock.handle) or { panic(err) }
	stale.closed = true
	defer { os.rm(path) or {} }
	before := os.lstat(path) or { panic(err) }
	if mut unexpected := listen(path) {
		unexpected.close() or {}
		assert false
	}
	assert (os.lstat(path) or { panic(err) }).inode == before.inode
	for invalid in ['', '/tmp/' + 'x'.repeat(99), '${path}\x00suffix'] {
		if mut unexpected := listen(invalid) {
			unexpected.close() or {}
			assert false, 'invalid path accepted'
		}
	}
}
