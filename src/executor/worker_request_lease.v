module executor

import net.unix
import sync

// A transferred connection and its accounting retain one origin and one finish.
// Copies may discard an unclaimed outcome, but cannot close a taken connection.
@[heap]
pub struct WorkerRequestLease {
pub:
	socket_path string
	finish_fn   fn (string) @[required]
mut:
	mu        sync.Mutex
	conn      ?&unix.StreamConn
	taken     bool
	finishing bool
	done      chan bool = chan bool{}
}

fn new_worker_request_lease(mut socket_port WorkerSocketFacade, path string) &WorkerRequestLease {
	mut retained := socket_port
	return &WorkerRequestLease{
		socket_path: path
		finish_fn:   fn [mut retained] (socket string) {
			retained.on_worker_request_finished(socket)
		}
	}
}

pub fn (mut lease WorkerRequestLease) retain_connection(conn &unix.StreamConn) {
	lease.mu.@lock()
	lease.conn = conn
	lease.mu.unlock()
}

fn (mut lease WorkerRequestLease) take_connection() ?&unix.StreamConn {
	lease.mu.@lock()
	defer { lease.mu.unlock() }
	if lease.taken || lease.finishing { return none }
	conn := lease.conn or { return none }
	lease.taken = true
	lease.conn = none
	return conn
}

fn (mut lease WorkerRequestLease) finish_owned(only_unclaimed bool) {
	lease.mu.@lock()
	if only_unclaimed && lease.taken {
		lease.mu.unlock()
		return
	}
	if lease.finishing {
		lease.mu.unlock()
		_ := <-lease.done
		return
	}
	lease.finishing = true
	owned := lease.conn
	lease.conn = none
	lease.mu.unlock()
	if mut conn := owned { conn.close() or {} }
	lease.finish_fn(lease.socket_path)
	lease.done.close()
}

pub fn (mut lease WorkerRequestLease) finish() { lease.finish_owned(false) }
