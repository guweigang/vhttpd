module worker

pub struct MetricsSnapshot {
pub:
	queue_waits_total    i64
	queue_rejected_total i64
	queue_timeouts_total i64
	queue_depth          int
	pool_size            i64
	backend_mode         string
	queue_capacity       int
	queue_timeout_ms     int
	stream_dispatch      bool
	lifecycle            string
}

pub fn (mut state WorkerState) metrics() MetricsSnapshot {
	state.mu.@lock()
	defer { state.mu.unlock() }
	return MetricsSnapshot{
		queue_waits_total:    state.stat_queue_waits_total
		queue_rejected_total: state.stat_queue_rejected_total
		queue_timeouts_total: state.stat_queue_timeouts_total
		queue_depth:          state.worker_backend.queue_waiting_requests
		pool_size:            i64(state.worker_backend.sockets.len)
		backend_mode:         '${state.worker_backend_mode}'
		queue_capacity:       state.worker_backend.queue_capacity
		queue_timeout_ms:     state.worker_backend.queue_timeout_ms
		stream_dispatch:      state.stream_dispatch
		lifecycle:            state.lifecycle
	}
}
