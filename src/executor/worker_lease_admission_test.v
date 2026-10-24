module executor

import net.unix
import os
import time

fn lease_admission_pair() (&unix.StreamConn, &unix.StreamConn) {
	path := os.join_path(os.temp_dir(), 'lease-admission-${os.getpid()}-${time.now().unix_micro()}.sock')
	mut listener := unix.listen_stream(path) or { panic(err) }
	defer {
		listener.close() or {}
		os.rm(path) or {}
	}
	conn := unix.connect_stream(path) or { panic(err) }
	return conn, listener.accept() or { panic(err) }
}

fn test_worker_lease_cannot_retain_after_finish() {
	mut conn, mut peer := lease_admission_pair()
	defer {
		conn.close() or {}
		peer.close() or {}
	}
	finished := chan bool{cap: 2}
	mut lease := &WorkerRequestLease{ finish_fn: fn [finished] (_ string) { finished <- true } }
	lease.finish()
	assert !lease.retain_connection(conn)
	assert lease.conn == none
	assert <-finished
	assert conn.write_string('caller-owned') or { panic(err) } == 12
	lease.finish()
	assert finished.len == 0
}

fn test_worker_lease_duplicate_retain_preserves_first_owner() {
	mut first, mut first_peer := lease_admission_pair()
	mut second, mut second_peer := lease_admission_pair()
	defer {
		first.close() or {}
		first_peer.close() or {}
		second.close() or {}
		second_peer.close() or {}
	}
	mut lease := &WorkerRequestLease{ finish_fn: fn (_ string) {} }
	defer { lease.finish() }
	assert lease.retain_connection(first)
	assert !lease.retain_connection(second)
	assert (lease.conn or { panic('missing first connection') }) == first
	assert second.write_string('caller-owned') or { panic(err) } == 12
}

fn test_worker_lease_cannot_retain_after_transfer() {
	mut first, mut first_peer := lease_admission_pair()
	mut second, mut second_peer := lease_admission_pair()
	defer {
		first.close() or {}
		first_peer.close() or {}
		second.close() or {}
		second_peer.close() or {}
	}
	mut lease := &WorkerRequestLease{ finish_fn: fn (_ string) {} }
	defer { lease.finish() }
	assert lease.retain_connection(first)
	assert (lease.take_connection() or { panic('missing connection') }) == first
	assert !lease.retain_connection(second)
	assert lease.conn == none
	assert second.write_string('caller-owned') or { panic(err) } == 12
}

fn lease_admission_finish(mut lease WorkerRequestLease) { lease.finish() }

fn test_worker_lease_retain_during_finish_is_rejected() {
	mut conn, mut peer := lease_admission_pair()
	defer {
		conn.close() or {}
		peer.close() or {}
	}
	entered := chan bool{}
	release := chan bool{}
	mut lease := &WorkerRequestLease{
		finish_fn: fn [entered, release] (_ string) {
			entered <- true
			_ := <-release
		}
	}
	task := spawn lease_admission_finish(mut lease)
	_ := <-entered
	assert !lease.retain_connection(conn)
	empty := lease.conn == none
	release <- true
	task.wait()
	assert empty
	assert conn.write_string('caller-owned') or { panic(err) } == 12
}

struct LeaseAdmissionAttempt {
	lease   &WorkerRequestLease
	conn    &unix.StreamConn
	start   chan bool
	results chan bool
}

fn lease_admission_attempt(attempt LeaseAdmissionAttempt) {
	_ := <-attempt.start
	mut lease := attempt.lease
	attempt.results <- lease.retain_connection(attempt.conn)
}

fn test_worker_lease_concurrent_admission_has_one_owner() {
	mut first, mut first_peer := lease_admission_pair()
	mut second, mut second_peer := lease_admission_pair()
	defer {
		first.close() or {}
		first_peer.close() or {}
		second.close() or {}
		second_peer.close() or {}
	}
	finished := chan bool{cap: 2}
	mut lease := &WorkerRequestLease{ finish_fn: fn [finished] (_ string) { finished <- true } }
	defer { lease.finish() }
	start := chan bool{cap: 2}
	results := chan bool{cap: 2}
	a := spawn lease_admission_attempt(LeaseAdmissionAttempt{ lease: lease, conn: first, start: start, results: results })
	b := spawn lease_admission_attempt(LeaseAdmissionAttempt{ lease: lease, conn: second, start: start, results: results })
	start <- true
	start <- true
	x := <-results
	y := <-results
	a.wait()
	b.wait()
	assert x != y
	owned := lease.take_connection() or { panic('missing winning connection') }
	assert owned == first || owned == second
	assert lease.take_connection() == none
	mut rejected := if owned == first { second } else { first }
	lease.finish()
	lease.finish()
	assert <-finished
	assert finished.len == 0
	assert rejected.write_string('caller-owned') or { panic(err) } == 12
}
