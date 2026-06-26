module main

import worker
import executor
import upstream.transport

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

fn test_engine_runtime_resolves_named_dispatch_and_worker_settings() {
	runtime := EngineRuntime{
		primary:    worker.WorkerState{
			worker_backend: worker.WorkerBackendRuntime{
				read_timeout_ms: 100
				env:             {
					'POOL': 'primary'
				}
			}
			logic_executor: executor.SocketWorkerExecutor{}
		}
		additional: {
			'php-cgi': &worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					read_timeout_ms: 200
					env:             {
						'POOL': 'cgi'
					}
				}
				logic_executor: executor.PhpCgiExecutor{}
			}
		}
	}
	selection := runtime.dispatch_selection('php-cgi')
	assert selection.pool == 'php-cgi'
	assert selection.executor_kind() == 'php-cgi'
	assert runtime.read_timeout_ms('php-cgi') == 200
	assert runtime.worker_env('php-cgi')['POOL'] == 'cgi'
}

fn test_engine_runtime_tracks_request_start_across_pools() {
	mut runtime := EngineRuntime{
		primary:    worker.WorkerState{
			worker_backend: worker.WorkerBackendRuntime{
				managed_workers: [
					transport.ManagedWorker{
						socket_path: '/tmp/primary.sock'
					},
				]
			}
		}
		additional: {
			'php-cgi': &worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					managed_workers: [
						transport.ManagedWorker{
							socket_path: '/tmp/cgi.sock'
						},
					]
				}
			}
		}
	}
	runtime.request_started('/tmp/cgi.sock')
	assert runtime.primary.worker_backend.managed_workers[0].inflight_requests == 0
	cgi := runtime.additional['php-cgi'] or { panic('missing php-cgi engine') }
	assert cgi.worker_backend.managed_workers[0].inflight_requests == 1
	runtime.request_finished(EngineLifecyclePort{}, '/tmp/cgi.sock')
	assert cgi.worker_backend.managed_workers[0].inflight_requests == 0
	assert cgi.worker_backend.managed_workers[0].served_requests == 1
}
