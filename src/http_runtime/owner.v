module http_runtime

import sync
import time
import veb

@[heap]
pub struct Run {
	key string
mut:
	entered bool
}

// An App can serve several endpoints. Each reservation owns one invocation;
// native listeners stay with veb, and terminal shutdown drains every invocation.
@[heap]
pub struct Owner {
mut:
	mu            sync.Mutex
	closed        bool
	runs          map[string]&Run
	handles       []&veb.Server
	ready_handles []&veb.Server
	stop_error    string
}

pub fn (mut owner Owner) reserve(key string) ?&Run {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.closed || key in owner.runs { return none }
	run := &Run{ key: key }
	owner.runs[key] = run
	return run
}

pub fn (mut owner Owner) accepting() bool {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	return !owner.closed
}

pub fn (mut owner Owner) serve(mut run Run, serve_fn fn ()) {
	owner.mu.@lock()
	current := owner.runs[run.key] or {
		owner.mu.unlock()
		return
	}
	if voidptr(current) != voidptr(&run) || run.entered {
		owner.mu.unlock()
		return
	}
	run.entered = true
	cancelled := owner.closed
	owner.mu.unlock()
	defer {
		owner.mu.@lock()
		owner.runs.delete(run.key)
		if owner.runs.len == 0 {
			owner.handles = []&veb.Server{}
			owner.ready_handles = []&veb.Server{}
		}
		owner.mu.unlock()
	}
	if !cancelled { serve_fn() }
}

pub fn (mut owner Owner) publish(server &veb.Server) {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.runs.len > 0 { owner.handles << server }
}

// Hooks from a shared App cannot identify their endpoint. Probe all published
// handles without waiting; only running servers have completed mark_starting.
pub fn (mut owner Owner) ready() {
	owner.mu.@lock()
	handles := owner.handles.clone()
	owner.mu.unlock()
	for server in handles {
		server.wait_till_running(max_retries: 0, retry_period_ms: 1) or {
			if err.msg() != 'maximum retries reached' {
				owner.mu.@lock()
				owner.stop_error = err.msg()
				owner.mu.unlock()
			}
			continue
		}
		owner.mu.@lock()
		present := owner.handles.any(voidptr(it) == voidptr(server))
		already_ready := owner.ready_handles.any(voidptr(it) == voidptr(server))
		if present && !already_ready { owner.ready_handles << server }
		stopping := present && owner.closed
		owner.mu.unlock()
		if stopping { owner.stop_handle(server) }
	}
}

pub fn (mut owner Owner) request_stop() {
	owner.mu.@lock()
	owner.closed = true
	handles := owner.ready_handles.clone()
	owner.mu.unlock()
	for server in handles { owner.stop_handle(server) }
}

fn (mut owner Owner) stop_handle(server &veb.Server) {
	// Start shutdown without waiting here. Completion belongs to serve().
	server.shutdown(timeout: 0) or {
		if !err.msg().starts_with('graceful shutdown timed out after ') {
			owner.mu.@lock()
			owner.stop_error = err.msg()
			owner.mu.unlock()
		}
	}
}

pub fn (mut owner Owner) wait_stopped() ! {
	for {
		owner.mu.@lock()
		active := owner.runs.len > 0
		message := owner.stop_error
		owner.mu.unlock()
		if message != '' { return error(message) }
		if !active { return }
		time.sleep(time.millisecond)
	}
}
