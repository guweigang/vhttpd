module main

import worker
import executor
import admin
import json
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

fn test_engine_runtime_marks_additional_engine_workers_draining() {
	mut runtime := EngineRuntime{
		additional: {
			'php-cgi': &worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					managed_workers: [
						transport.ManagedWorker{
							socket_path:       '/tmp/cgi-a.sock'
							inflight_requests: 2
						},
						transport.ManagedWorker{
							socket_path: '/tmp/cgi-b.sock'
						},
					]
				}
			}
		}
	}

	status := runtime.drain_engine('php-cgi') or { panic(err) }
	cgi := runtime.additional['php-cgi'] or { panic('missing php-cgi engine') }
	second := runtime.drain_engine('php-cgi') or { panic(err) }

	assert status.engine == 'php-cgi'
	assert status.worker_count == 2
	assert status.draining_count == 2
	assert status.inflight_requests == 2
	assert status.ready_count == 1
	assert status.changed
	assert cgi.worker_backend.managed_workers[0].draining
	assert cgi.worker_backend.managed_workers[1].draining
	assert !second.changed
	assert second.draining_count == 2
}

fn test_engine_runtime_reads_drain_status_without_mutating_workers() {
	mut runtime := EngineRuntime{
		additional: {
			'php-cgi': &worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					managed_workers: [
						transport.ManagedWorker{
							socket_path:       '/tmp/cgi-a.sock'
							inflight_requests: 1
						},
					]
				}
			}
		}
	}

	status := runtime.engine_drain_status('php-cgi') or { panic(err) }
	cgi := runtime.additional['php-cgi'] or { panic('missing php-cgi engine') }

	assert status.engine == 'php-cgi'
	assert status.worker_count == 1
	assert status.draining_count == 0
	assert status.inflight_requests == 1
	assert status.ready_count == 0
	assert !status.changed
	assert !cgi.worker_backend.managed_workers[0].draining
}

fn test_engine_runtime_resumes_draining_workers() {
	mut runtime := EngineRuntime{
		additional: {
			'php-cgi': &worker.WorkerState{
				worker_backend: worker.WorkerBackendRuntime{
					managed_workers: [
						transport.ManagedWorker{
							socket_path:       '/tmp/cgi-a.sock'
							inflight_requests: 1
							draining:          true
						},
					]
				}
			}
		}
	}

	status := runtime.resume_engine('php-cgi') or { panic(err) }
	cgi := runtime.additional['php-cgi'] or { panic('missing php-cgi engine') }
	second := runtime.resume_engine('php-cgi') or { panic(err) }

	assert status.engine == 'php-cgi'
	assert status.worker_count == 1
	assert status.draining_count == 0
	assert status.inflight_requests == 1
	assert status.changed
	assert !cgi.worker_backend.managed_workers[0].draining
	assert !second.changed
}

fn test_replacement_worker_readiness_skips_disabled_worker_backend() {
	state := worker.WorkerState{
		worker_backend_mode: .disabled
	}

	validate_replacement_worker_state_ready('vjsx', state) or { panic(err) }
}

fn test_replacement_worker_readiness_skips_external_worker_backend() {
	state := worker.WorkerState{
		worker_backend_mode: .required
		worker_backend:      worker.WorkerBackendRuntime{
			sockets:   ['/tmp/external-worker.sock']
			autostart: false
		}
	}

	validate_replacement_worker_state_ready('php', state) or { panic(err) }
}

fn test_replacement_worker_readiness_rejects_unready_autostart_pool() {
	state := worker.WorkerState{
		worker_backend_mode: .required
		worker_backend:      worker.WorkerBackendRuntime{
			sockets:         ['/tmp/vhttpd-missing-replacement-worker.sock']
			autostart:       true
			managed_workers: [
				transport.ManagedWorker{
					socket_path: '/tmp/vhttpd-missing-replacement-worker.sock'
				},
			]
		}
	}

	if _ := validate_replacement_worker_state_ready('php', state) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_replacement_engine_not_ready:php'
	}
}

fn test_engine_runtime_drain_unknown_engine_reports_error() {
	mut runtime := EngineRuntime{}

	if _ := runtime.drain_engine('missing') {
		assert false
	} else {
		assert err.msg() == 'unknown_executor_kind:missing'
	}
}

fn test_internal_admin_worker_drain_marks_engine_workers() {
	mut app := App{
		engines: EngineRuntime{
			additional: {
				'php-cgi': &worker.WorkerState{
					worker_backend: worker.WorkerBackendRuntime{
						managed_workers: [
							transport.ManagedWorker{
								socket_path:       '/tmp/cgi-a.sock'
								inflight_requests: 1
							},
						]
					}
				}
			}
		}
	}

	resp := app.internal_admin_dispatch(admin.InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'POST'
		path:   '/admin/workers/drain'
		query:  {
			'engine': 'php-cgi'
		}
	})
	status := json.decode(EngineDrainStatus, resp.body) or { panic(err) }
	cgi := app.engines.additional['php-cgi'] or { panic('missing php-cgi engine') }

	assert resp.status == 200
	assert status.engine == 'php-cgi'
	assert status.draining_count == 1
	assert status.inflight_requests == 1
	assert cgi.worker_backend.managed_workers[0].draining
}
