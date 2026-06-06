module main

import worker

fn test_worker_backend_runtime_defaults_to_php_backend() {
	rt := worker.WorkerBackendRuntime{}
	assert rt.kind() == 'php'
	assert !rt.enabled()
}

fn test_worker_backend_runtime_enabled_when_sockets_present() {
	rt := worker.WorkerBackendRuntime{
		sockets: ['/tmp/test.sock']
	}
	assert rt.enabled()
}
