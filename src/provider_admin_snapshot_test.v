module main

import codex
import provider
import executor
import worker
import time

fn snapshot_provider_app() &App {
	return &App{
		providers: ProviderRuntimeHub{
			codex:     codex.CodexState{ runtime: codex.ProviderRuntime{ enabled: true, url: 'ws://old/main' } }
			instances: provider.ProviderInstanceRegistry{
				specs: {
					'codex/extra': provider.ProviderInstanceSpec{ provider: 'codex', instance: 'extra', config_json: '{"url":"ws://old/extra"}' }
				}
			}
		}
	}
}

fn test_provider_directory_and_launch_urls_stay_in_same_view() {
	mut app := snapshot_provider_app()
	ctx := app.build_provider_runtime_dispatch_context()
	assert ctx.instances('codex') == ['extra', 'main']
	assert ctx.gateway_count() == 2
	app.mu.@lock()
	app.providers.instances.specs.delete('codex/extra')
	app.providers.codex.mu.@lock()
	app.providers.codex.runtime.url = 'ws://new/main'
	app.providers.codex.runtime.enabled = false
	app.providers.codex.mu.unlock()
	app.mu.unlock()
	assert ctx.instances('codex') == ['extra', 'main']
	assert ctx.upstream_enabled('codex', 'extra')
	assert ctx.gateway_count() == 2
	launches := ctx.upstream_launches()
	assert launches.len == 2
	assert launches[0].url == 'ws://old/extra'
	assert launches[1].url == 'ws://old/main'
	fresh := app.build_provider_runtime_dispatch_context()
	assert fresh.instances('codex').len == 0
	assert fresh.gateway_count() == 0
}

fn test_readonly_provider_views_do_not_initialize_runtime_instances() {
	mut app := snapshot_provider_app()
	assert app.providers.codex.instances.len == 0
	assert app.providers.codex.runtime.instance == ''
	ctx := app.build_provider_runtime_dispatch_context()
	for _ in 0 .. 3 {
		assert ctx.upstream_launches().len == 2
	}
	_ := app.build_admin_context()
	assert app.providers.codex.instances.len == 0
	assert app.providers.codex.runtime.instance == ''
	// The explicit lifecycle operation still registers the same resolved config.
	extra := app.codex_runtime_ensure_instance('extra')
	assert extra.url == 'ws://old/extra'
	assert app.providers.codex.instances.len == 1
}

fn test_provider_url_error_belongs_to_original_view() {
	mut app := snapshot_provider_app()
	app.providers.codex.runtime.url = ''
	ctx := app.build_provider_runtime_dispatch_context()
	app.providers.codex.runtime.url = 'ws://configured/later'
	if _ := ctx.pull_url('codex', 'default') {
		assert false
	} else {
		assert err.msg() == 'codex url not configured'
	}
	fresh := app.build_provider_runtime_dispatch_context()
	assert fresh.pull_url('codex', 'main') or { panic(err) } == 'ws://configured/later'
	assert ctx.upstream_launches()[1].url == ''
}

fn test_provider_context_returns_independent_instance_arrays() {
	mut app := snapshot_provider_app()
	ctx := app.build_provider_runtime_dispatch_context()
	mut names := ctx.instances('codex')
	names[0] = 'poison'
	names << 'added'
	assert ctx.instances('codex') == ['extra', 'main']
	assert !ctx.upstream_enabled('codex', 'poison')
	assert !ctx.ready('unknown')
}

fn test_admin_engine_metrics_are_one_snapshot_until_next_context() {
	mut state := &worker.WorkerState{ lifecycle: 'old', worker_backend: worker.WorkerBackendRuntime{ queue_capacity: 3, queue_waiting_requests: 2, sockets: ['a'] } }
	mut app := &App{ engines: EngineRuntime{ primary: state } }
	ctx := app.build_admin_context()
	state.mu.@lock()
	state.worker_backend.queue_capacity = 9
	state.worker_backend.queue_waiting_requests = 8
	state.mu.unlock()
	app.mu.@lock()
	app.engines = EngineRuntime{ primary: &worker.WorkerState{ lifecycle: 'new', logic_executor: executor.DisabledLogicExecutor{}, worker_backend: worker.WorkerBackendRuntime{ queue_capacity: 20 } } }
	app.mu.unlock()
	assert ctx.worker_queue_capacity() == 3
	assert ctx.worker_queue_depth() == 2
	assert ctx.worker_pool_size() == 1
	assert ctx.worker_lifecycle() == 'old'
	assert ctx.logic_executor_kind() == 'php'
	fresh := app.build_admin_context()
	assert fresh.worker_queue_capacity() == 20
	assert fresh.worker_lifecycle() == 'new'
	assert fresh.logic_executor_kind() == 'none'
}

fn test_admin_pipeline_and_provider_directory_keep_original_publication() {
	mut app := snapshot_provider_app()
	app.pipelines.http = HttpRoutingRuntime{ listener_id: 'old' }
	ctx := app.build_admin_context()
	app.mu.@lock()
	app.pipelines.http = HttpRoutingRuntime{ listener_id: 'new' }
	app.providers.instances.specs.clear()
	app.providers.codex.runtime.enabled = false
	app.mu.unlock()
	assert ctx.pipeline_runtime_snapshot().listener_id == 'old'
	assert ctx.provider_runtime_gateway_count() == 2
	fresh := app.build_admin_context()
	assert fresh.pipeline_runtime_snapshot().listener_id == 'new'
	assert fresh.provider_runtime_gateway_count() == 0
}

struct AdminSnapshotExecutor {
	executor.DisabledLogicExecutor
	owner &App @[required]
}

fn (e AdminSnapshotExecutor) kind() string { return 'admin-original' }

fn (e AdminSnapshotExecutor) admin_details() executor.LogicExecutorAdminDetails {
	mut app := e.owner
	app.mu.@lock()
	app.engines = EngineRuntime{ primary: &worker.WorkerState{ logic_executor: executor.DisabledLogicExecutor{} } }
	app.pipelines.http = HttpRoutingRuntime{ listener_id: 'replaced-in-callback' }
	app.mu.unlock()
	return executor.LogicExecutorAdminDetails{ kind: 'admin-original' }
}

fn test_admin_executor_description_runs_outside_publication_lock() {
	mut app := &App{}
	app.engines = EngineRuntime{ primary: &worker.WorkerState{ logic_executor: AdminSnapshotExecutor{ owner: app } } }
	app.pipelines.http = HttpRoutingRuntime{ listener_id: 'original' }
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		ctx := app.build_admin_context()
		assert ctx.logic_executor_kind() == 'admin-original'
		assert ctx.logic_executor_admin_details().kind == 'admin-original'
		assert ctx.pipeline_runtime_snapshot().listener_id == 'original'
		done <- true
	}()
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('admin context deadlocked')
		}
	}
	assert app.engine_runtime_snapshot().primary_kind() == 'none'
}
