module executor

pub struct ExecutorLoad {
pub:
	available               bool
	embedded                bool
	concurrency_observed    bool
	capacity                int
	occupied                int
	inflight                int
	waiting                 int
	usable                  int
	stopping                bool
	queue_waits_total       i64
	queue_timeouts_total    i64
	last_queue_timeout_unix i64
	queue_timeout_ms        int
	queue_capacity          int = -1
	execution_timeout_ms    int
}

pub fn (e InProcVjsxExecutor) http_load_snapshot() ExecutorLoad {
	mut state := e.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	mut occupied := 0
	mut inflight := 0
	mut usable := 0
	for lane in state.lanes {
		if lane.inflight > 0 { occupied++ }
		inflight += lane.inflight
		if lane.healthy || lane.dirty { usable++ }
	}
	return ExecutorLoad{ available: true, embedded: true, concurrency_observed: true, capacity: state.lanes.len, occupied: occupied, inflight: inflight, usable: usable, waiting: state.http_waiting, stopping: state.stopping, queue_waits_total: state.http_queue_waits, queue_timeouts_total: state.http_queue_timeouts, last_queue_timeout_unix: state.http_last_queue_timeout, queue_timeout_ms: inproc_vjsx_lane_wait_timeout_ms }
}
