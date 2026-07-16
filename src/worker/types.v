module worker

import executor
import sync
import upstream.transport

// WorkerBackend is the interface for backend worker implementations.
pub interface WorkerBackend {
	kind() string
}

// PhpWorkerBackend implements WorkerBackend for PHP workers.
pub struct PhpWorkerBackend {}

pub fn (b PhpWorkerBackend) kind() string {
	_ = b
	return 'php'
}

// WorkerBackendRuntime holds the configuration and pool state for a worker backend.
pub struct WorkerBackendRuntime {
pub mut:
	backend                WorkerBackend = PhpWorkerBackend{}
	sockets                []string
	read_timeout_ms        int
	rr_index               int
	autostart              bool
	cmd                    string
	env                    map[string]string
	workdir                string
	restart_backoff_ms     int
	restart_backoff_max_ms int
	max_requests           int
	queue_capacity         int
	queue_timeout_ms       int
	queue_poll_ms          int
	managed_workers        []transport.ManagedWorker
	queue_waiting_requests int
}

pub fn (rt &WorkerBackendRuntime) kind() string {
	return rt.backend.kind()
}

pub fn (rt &WorkerBackendRuntime) enabled() bool {
	return rt.sockets.len > 0
}

// WorkerState holds the worker subsystem state.
pub struct WorkerState {
pub mut:
	mu                  sync.Mutex
	worker_backend      WorkerBackendRuntime
	worker_backend_mode executor.WorkerBackendMode = .required
	logic_executor      executor.LogicExecutor     = executor.SocketWorkerExecutor{}
	lifecycle           string
	stream_dispatch     bool
	stat_queue_waits_total    i64
	stat_queue_rejected_total i64
	stat_queue_timeouts_total i64
}
