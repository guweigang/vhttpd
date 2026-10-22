module listener_runtime

import net.unix
import os
import time

fn owner_test_path() string {
	return '/tmp/vhttpd-owner-${os.getpid()}-${time.now().unix_micro()}.sock'
}

fn test_stop_before_publish_keeps_reservation_and_rejects_late_handle() {
	mut owner := Owner{}
	generation := owner.reserve() or { panic('no reservation') }
	owner.request_stop()
	assert owner.should_stop(generation)
	assert owner.reserve() == none
	path := owner_test_path()
	mut candidate := listen(path) or { panic(err) }
	assert !owner.publish(generation, candidate)
	candidate.close() or { panic(err) }
	assert owner.finish(generation)
	assert owner.reserve() or { panic('cannot restart') } > generation
}

fn test_finish_closes_once_and_stale_finish_preserves_new_socket() {
	mut owner := Owner{}
	first := owner.reserve() or { panic('no reservation') }
	path := owner_test_path()
	listener := listen(path) or { panic(err) }
	assert owner.publish(first, listener)
	owner.request_stop()
	owner.request_stop()
	assert os.exists(path)
	assert owner.reserve() == none
	assert owner.finish(first)
	assert !os.exists(path)
	second := owner.reserve() or { panic('no restart') }
	replacement := listen(path) or { panic(err) }
	assert owner.publish(second, replacement)
	assert !owner.finish(first)
	assert !owner.publish(first, listener)
	assert os.exists(path)
	assert !owner.should_stop(second)
	assert owner.finish(second)
	assert !owner.finish(second)
}

fn reserve_once(mut owner Owner, gate chan bool, result chan bool) {
	_ := <-gate
	if _ := owner.reserve() { result <- true } else { result <- false }
}

fn test_concurrent_starts_have_one_owner() {
	mut owner := &Owner{}
	gate := chan bool{cap: 16}
	result := chan bool{cap: 16}
	for _ in 0 .. 16 { spawn reserve_once(mut owner, gate, result) }
	for _ in 0 .. 16 { gate <- true }
	mut winners := 0
	for _ in 0 .. 16 { if <-result { winners++ } }
	assert winners == 1
	assert owner.finish(1)
}

fn test_accepted_request_admission_and_completion_hold_generation() {
	mut owner := Owner{}
	generation := owner.reserve() or { panic('no reservation') }
	path := owner_test_path()
	mut listener := listen(path) or { panic(err) }
	defer { listener.close() or {} }
	mut peer := unix.connect_stream(path) or { panic(err) }
	defer { peer.close() or {} }
	mut conn := listener.accept() or { panic(err) }
	request := owner.accept_request(generation, conn.sock.handle) or { panic('not registered') }
	assert C.fcntl(owner.requests[request].interrupt, C.F_GETFD) & C.FD_CLOEXEC != 0
	assert !owner.begin_request(generation + 1, request)
	assert owner.begin_request(generation, request)
	assert !owner.begin_request(generation, request)
	owner.request_stop()
	assert owner.accept_request(generation, conn.sock.handle) == none
	assert !owner.finish(generation)
	assert owner.active_requests(generation) == 1
	conn.close() or { panic(err) }
	owner.complete_request(request)
	owner.complete_request(request)
	owner.drain_requests(generation)
	assert owner.finish(generation)
	next := owner.reserve() or { panic('no restart') }
	assert !owner.begin_request(next, request)
	owner.complete_request(request)
	assert owner.finish(next)
}

fn test_stop_interrupts_read_and_rejects_pending_dispatch() {
	mut owner := Owner{}
	generation := owner.reserve() or { panic('no reservation') }
	path := owner_test_path()
	mut listener := listen(path) or { panic(err) }
	defer { listener.close() or {} }
	mut peer := unix.connect_stream(path) or { panic(err) }
	defer { peer.close() or {} }
	mut conn := listener.accept() or { panic(err) }
	request := owner.accept_request(generation, conn.sock.handle) or { panic('not registered') }
	owner.request_stop()
	assert !owner.begin_request(generation, request)
	mut bytes := []u8{len: 4}
	assert (conn.read(mut bytes) or { 0 }) <= 0
	conn.close() or { panic(err) }
	owner.complete_request(request)
	owner.drain_requests(generation)
	assert owner.finish(generation)
}

fn test_terminal_shutdown_before_start_prevents_reservation_permanently() {
	mut owner := Owner{}
	assert owner.request_shutdown() == none
	assert owner.reserve() == none
	assert owner.request_stop() == none
	assert owner.reserve() == none
}

fn test_terminal_shutdown_drains_generation_without_permitting_restart() {
	mut owner := Owner{}
	generation := owner.reserve() or { panic('generation') }
	path := owner_test_path()
	listener := listen(path) or { panic(err) }
	assert owner.publish(generation, listener)
	assert (owner.request_shutdown() or { panic('stop') }) == generation
	assert owner.should_stop(generation)
	assert owner.reserve() == none
	assert owner.finish(generation)
	owner.wait_stopped(generation)
	assert !os.exists(path)
	assert owner.reserve() == none
	assert owner.request_shutdown() == none
}
