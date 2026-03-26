module main

pub interface WorkerBackend {
	kind() string
}

pub struct PhpWorkerBackend {}

pub fn (b PhpWorkerBackend) kind() string {
	_ = b
	return 'php'
}

pub struct WorkerBackendRuntime {
pub mut:
	backend               WorkerBackend = PhpWorkerBackend{}
	sockets               []string
	read_timeout_ms       int
	rr_index              int
	autostart             bool
	cmd                   string
	env                   map[string]string
	workdir               string
	restart_backoff_ms    int
	restart_backoff_max_ms int
	max_requests          int
	queue_capacity        int
	queue_timeout_ms      int
	queue_poll_ms         int
	managed_workers       []ManagedWorker
	queue_waiting_requests int
}

pub fn (rt WorkerBackendRuntime) kind() string {
	return rt.backend.kind()
}

pub fn (rt WorkerBackendRuntime) enabled() bool {
	return rt.sockets.len > 0
}
