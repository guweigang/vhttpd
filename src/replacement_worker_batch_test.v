module main

import config
import executor
import os
import runtime_plan
import worker
import upstream.transport

fn batch_test_worker(socket string, draining bool) &worker.WorkerState {
	return &worker.WorkerState{
		logic_executor: executor.SocketWorkerExecutor{}
		worker_backend: worker.WorkerBackendRuntime{
			managed_workers: [transport.ManagedWorker{ socket_path: socket, draining: draining, inflight_requests: 1 }]
		}
	}
}

fn batch_test_config() string {
	return '
version = 2
[listeners.web]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 18080
[engines.a-main]
kind = "php-worker"
entry = "/tmp/a-old.php"
[engines.z-extra]
kind = "php-worker"
entry = "/tmp/z-old.php"
[adapters.a-main]
kind = "http-handler"
engine = "engine:a-main"
[adapters.z-extra]
kind = "http-handler"
engine = "engine:z-extra"
[[pipelines]]
id = "main"
ingress = "listener:web"
match.paths = ["*"]
egress = "adapter:a-main"
[[pipelines]]
id = "extra"
ingress = "listener:web"
match.paths = ["/extra/*"]
egress = "adapter:z-extra"
'
}

fn test_apply_invalid_later_pool_does_not_leave_unowned_draining_workers() {
	dir := os.join_path(os.temp_dir(), 'vhttpd-batch-apply-${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	current_file := os.join_path(dir, 'current.toml')
	next_file := os.join_path(dir, 'next.toml')
	text := batch_test_config()
	os.write_file(current_file, text) or { panic(err) }
	os.write_file(next_file, text.replace('-old.php', '-new.php')) or { panic(err) }
	plan := config.load_runtime_plan_file(current_file) or { panic(err) }
	mut app := &App{
		plan:          plan
		engines:       EngineRuntime{ primary: batch_test_worker('/tmp/batch-main.sock', false) }
		pipelines:     PipelineRuntime.new(plan, 'web', runtime_routes_from_plan(plan, 'web'), '', '', map[string]string{}, map[string]&worker.WorkerState{})
		control_plane: ControlPlaneRuntime{ event_log: os.join_path(dir, 'events.ndjson') }
	}
	prior := transport.ManagedWorker{ socket_path: '/tmp/prior-drain.sock', draining: true, inflight_requests: 3 }
	app.engines.primary.worker_backend.managed_workers << prior
	result := app.apply_runtime_plan_replacement(next_file) or { panic(err) }
	assert !result.applied
	assert result.status == 'rejected'
	assert result.preview.drain_engines == ['a-main', 'z-extra']
	assert result.error == 'runtime_plan_replacement_engine_has_no_worker_pool:z-extra'
	assert result.drains.len == 0
	assert !app.replacement.pending.active
	assert !app.replacement.operation_active
	assert !app.engines.primary.worker_backend.managed_workers[0].draining
	assert app.engines.primary.worker_backend.managed_workers[1].draining
	assert app.engines.primary.worker_backend.managed_workers[1].inflight_requests == 3
	events := os.read_file(app.control_plane.event_log) or { panic(err) }
	assert !events.contains('"type":"admin.worker.drain"')
	assert events.contains('"type":"runtime.plan.replacement.rejected"')
	// Correct the unavailable pool and retry the same config: rejection has
	// neither consumed the workflow admission nor left an untracked drain.
	app.engines.additional['z-extra'] = &worker.WorkerState{
		logic_executor: executor.SocketWorkerExecutor{}
		worker_backend: worker.WorkerBackendRuntime{
			managed_workers: [transport.ManagedWorker{ socket_path: '/tmp/batch-extra.sock', inflight_requests: 2 }]
		}
	}
	retry := app.apply_runtime_plan_replacement(next_file) or { panic(err) }
	assert retry.status == 'draining'
	assert retry.error == ''
	assert retry.drains.len == 2
	assert retry.drains[0].engine == 'main'
	assert retry.drains[0].inflight_requests == 4
	assert retry.drains[1].engine == 'z-extra'
	assert retry.drains[1].inflight_requests == 2
	assert app.replacement.pending.active
	assert app.replacement.pending.drain_engines == ['a-main', 'z-extra']
	assert app.engines.primary.worker_backend.managed_workers[0].draining
	extra_state := app.engines.additional['z-extra'] or { panic('repaired extra pool is absent') }
	assert extra_state.worker_backend.managed_workers[0].draining
	completed := app.cancel_runtime_plan_replacement()
	assert completed.cancelled
	assert completed.resumed.len == 2
	assert !app.replacement.pending.active
	assert !app.engines.primary.worker_backend.managed_workers[0].draining
	assert !extra_state.worker_backend.managed_workers[0].draining
	after := os.read_file(app.control_plane.event_log) or { panic(err) }
	assert after.count('"type":"admin.worker.drain"') == 2
	assert after.count('"type":"admin.worker.resume"') == 2
}

fn test_cancel_invalid_later_pool_keeps_all_pending_workers_draining() {
	mut app := &App{
		plan:        runtime_plan.RuntimePlan{
			engines: {
				'missing': runtime_plan.EnginePlan{ id: 'missing', kind: 'php-worker' }
			}
		}
		engines:     EngineRuntime{ primary: batch_test_worker('/tmp/batch-cancel.sock', true) }
		replacement: RuntimePlanReplacementRuntime{
			pending: RuntimePlanReplacementPendingSnapshot{
				active:        true
				config_path:   'original'
				strategy:      'engine_drain_required'
				drain_engines: ['main', 'missing']
			}
		}
	}
	generation := app.replacement.pending_generation
	result := app.cancel_runtime_plan_replacement()
	assert !result.cancelled
	assert result.error == 'runtime_plan_replacement_engine_has_no_worker_pool:missing'
	assert result.resumed.len == 0
	assert app.engines.primary.worker_backend.managed_workers[0].draining
	assert app.engines.primary.worker_backend.managed_workers[0].inflight_requests == 1
	assert app.replacement.pending.active
	assert app.replacement.pending.config_path == 'original'
	assert app.replacement.pending_generation == generation
	assert !app.replacement.operation_active
	app.engines.additional['missing'] = &worker.WorkerState{
		logic_executor: executor.SocketWorkerExecutor{}
		worker_backend: worker.WorkerBackendRuntime{
			managed_workers: [transport.ManagedWorker{ socket_path: '/tmp/batch-missing.sock', draining: true, inflight_requests: 2 }]
		}
	}
	retry := app.cancel_runtime_plan_replacement()
	assert retry.cancelled
	assert retry.resumed.len == 2
	assert retry.resumed[0].engine == 'main'
	assert retry.resumed[0].changed
	assert retry.resumed[0].inflight_requests == 1
	assert retry.resumed[1].engine == 'missing'
	assert retry.resumed[1].changed
	assert retry.resumed[1].inflight_requests == 2
	assert !app.replacement.pending.active
	assert app.replacement.pending_generation > generation
	assert !app.engines.primary.worker_backend.managed_workers[0].draining
	repaired := app.engines.additional['missing'] or { panic('repaired missing pool is absent') }
	assert !repaired.worker_backend.managed_workers[0].draining
}

fn test_cancel_unknown_later_engine_preserves_worker_counters_and_pending() {
	mut app := &App{
		plan:        runtime_plan.RuntimePlan{
			engines: {
				'known': runtime_plan.EnginePlan{ id: 'known', kind: 'php-worker' }
			}
		}
		engines:     EngineRuntime{ primary: batch_test_worker('/tmp/batch-unknown.sock', true) }
		replacement: RuntimePlanReplacementRuntime{
			pending: RuntimePlanReplacementPendingSnapshot{
				active:        true
				drain_engines: ['main', 'ghost']
			}
		}
	}
	result := app.cancel_runtime_plan_replacement()
	assert result.error == 'runtime_plan_replacement_unknown_engine_pool:ghost'
	assert result.resumed.len == 0
	assert app.replacement.pending.active
	assert app.engines.primary.worker_backend.managed_workers[0].draining
	assert app.engines.primary.worker_backend.managed_workers[0].inflight_requests == 1
}

fn test_cancel_aliases_keep_input_order_and_existing_change_semantics() {
	mut app := &App{
		engines:     EngineRuntime{
			primary:    batch_test_worker('/tmp/batch-alias.sock', true)
			additional: {
				'extra': &worker.WorkerState{
					logic_executor: executor.SocketWorkerExecutor{}
					worker_backend: worker.WorkerBackendRuntime{
						managed_workers: [transport.ManagedWorker{ socket_path: '/tmp/batch-alias-extra.sock', draining: true }]
					}
				}
			}
		}
		replacement: RuntimePlanReplacementRuntime{
			pending: RuntimePlanReplacementPendingSnapshot{
				active:        true
				drain_engines: ['primary', 'main', 'extra']
			}
		}
	}
	result := app.cancel_runtime_plan_replacement()
	assert result.cancelled
	assert result.resumed.map(it.engine) == ['main', 'main', 'extra']
	assert result.resumed[0].changed
	assert !result.resumed[1].changed
	assert result.resumed[2].changed
	assert !app.replacement.pending.active
}
