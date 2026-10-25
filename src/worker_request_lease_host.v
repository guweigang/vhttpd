module main

import worker
import net.unix
import sync

// One request owns its current selection across retry, dial and completion.
@[heap]
struct WorkerRequestLeaseHost {
	snapshot WorkerBackendRequestSnapshot
mut:
	mu        sync.Mutex
	lease     ?&worker.RequestLease
	selecting bool
	completed bool
}

fn (mut host WorkerRequestLeaseHost) select_socket() !string {
	host.mu.@lock()
	if host.selecting || host.completed || host.lease != none {
		host.mu.unlock()
		return error('worker_request_lease_in_use')
	}
	host.selecting = true
	host.mu.unlock()
	mut state := host.snapshot.state
	lease := state.select_request_queued(host.snapshot.port, host.snapshot.kind) or {
		host.mu.@lock()
		host.selecting = false
		host.mu.unlock()
		return err
	}
	host.mu.@lock()
	host.lease = lease
	host.selecting = false
	host.mu.unlock()
	return lease.socket_path
}

fn (mut host WorkerRequestLeaseHost) connect(path string) !&unix.StreamConn {
	host.mu.@lock()
	mut lease := host.lease or {
		host.mu.unlock()
		return error('worker_request_not_selected')
	}
	host.mu.unlock()
	if lease.socket_path != path { return error('worker_request_socket_mismatch') }
	return lease.connect()
}

fn (mut host WorkerRequestLeaseHost) release(path string) {
	host.mu.@lock()
	if mut lease := host.lease {
		if lease.socket_path != path {
			host.mu.unlock()
			return
		}
		host.lease = none
		host.mu.unlock()
		lease.release(host.snapshot.port)
		return
	}
	host.mu.unlock()
}

fn (mut host WorkerRequestLeaseHost) finish(path string) {
	host.mu.@lock()
	if host.completed {
		host.mu.unlock()
		return
	}
	if mut lease := host.lease {
		if lease.socket_path != path {
			host.mu.unlock()
			return
		}
		host.lease = none
		host.completed = true
		host.mu.unlock()
		lease.finish(host.snapshot.port)
		return
	}
	host.completed = true
	host.mu.unlock()
}

fn (mut host WorkerRequestLeaseHost) connector_context() worker.ConnectorContext {
	return worker.ConnectorContext{
		select_socket_fn: fn [mut host] () !string { return host.select_socket() }
		connect_fn:       fn [mut host] (path string) !&unix.StreamConn {
			return host.connect(path)
		}
		release_fn:       fn [mut host] (path string) { host.release(path) }
		emit_fn:          host.snapshot.port.emit_fn
	}
}

fn (mut host WorkerRequestLeaseHost) open() !worker.WorkerBackendConnection {
	path, conn := worker.ConnectorRuntime.connect_selected(host.connector_context())!
	return worker.WorkerBackendConnection.from_selected(path, conn)
}
