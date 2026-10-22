module main

import executor
import json2 as json
import time
import veb
import worker

struct AdminExecutorRoute {
	pipeline_id string
	engine_id   string
	adapter_id  string
}

struct AdminExecutorLoad {
	listener_id string
	pool        string
	primary     bool
	kind        string
	engine_ids  []string
	routes      []AdminExecutorRoute
	load        executor.ExecutorLoad
}

struct AdminExecutorLoads {
	at_unix   i64
	instances []AdminExecutorLoad
}

fn executor_instance_load(mut state worker.WorkerState) executor.ExecutorLoad {
	logic := state.logic_executor
	if logic is executor.InProcVjsxExecutor { return logic.http_load_snapshot() }
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.worker_backend.sockets.len == 0 { return executor.ExecutorLoad{} }
	mut occupied := 0
	mut inflight := 0
	for item in state.worker_backend.managed_workers {
		if item.inflight_requests > 0 { occupied++ }
		inflight += int(item.inflight_requests)
	}
	return executor.ExecutorLoad{ available: true, concurrency_observed: state.worker_backend.managed_workers.len == state.worker_backend.sockets.len, capacity: state.worker_backend.sockets.len, occupied: occupied, inflight: inflight, usable: state.worker_backend.sockets.len, waiting: state.worker_backend.queue_waiting_requests, queue_waits_total: state.stat_queue_waits_total, queue_timeouts_total: state.stat_queue_timeouts_total, queue_timeout_ms: state.worker_backend.queue_timeout_ms, queue_capacity: state.worker_backend.queue_capacity, execution_timeout_ms: state.worker_backend.read_timeout_ms }
}

fn (r &ActiveRuntimeRegistry) executor_loads() AdminExecutorLoads {
	r.mu.@lock()
	apps := r.apps.clone()
	cfgs := r.cfgs.clone()
	r.mu.unlock()
	mut instances := []AdminExecutorLoad{}
	mut seen := map[string]bool{}
	for i, app in apps {
		cfg := cfgs[i] or { continue }
		if !cfg.serve_data_plane || seen[cfg.plan_listener_id] { continue }
		seen[cfg.plan_listener_id] = true
		view := app.http_dispatch_view()
		mut pools := ['']
		mut keys := view.engines.additional.keys()
		keys.sort()
		pools << keys
		mut states := []&worker.WorkerState{}
		for pool in pools {
			mut state := if pool == '' {
				view.engines.primary
			} else {
				view.engines.additional[pool] or { continue }
			}
			if states.any(it == state) || state.logic_executor.kind() == 'none' { continue }
			states << state
			mut routes := []AdminExecutorRoute{}
			mut ids := []string{}
			for rule in view.pipelines.http.rules {
				if rule.status > 0 || rule.executor in ['static', 'upload', 'relay-delivery',
					'provider-action', 'none'] {
					continue
				}
				selected := view.engines.lookup_engine(rule.dispatch_executor(), .dispatch_pool) or { continue }
				if selected.state != state { continue }
				routes << AdminExecutorRoute{ pipeline_id: rule.pipeline_id, engine_id: rule.engine_id, adapter_id: rule.egress_ref.trim_string_left('adapter:') }
				if rule.engine_id != '' && rule.engine_id !in ids { ids << rule.engine_id }
			}
			if pool in view.plan.engines && pool !in ids { ids << pool }
			instances << AdminExecutorLoad{ listener_id: cfg.plan_listener_id, pool: if pool == '' {
				'main'
			} else {
				pool
			}, primary: pool == '', kind: state.logic_executor.kind(), engine_ids: ids, routes: routes, load: executor_instance_load(mut state) }
		}
	}
	return AdminExecutorLoads{ at_unix: time.now().unix(), instances: instances }
}

fn read_executor_loads() AdminExecutorLoads {
	unsafe { return g_active_runtime_registry.executor_loads()
	 }
}

@['/admin/http/executors'; get]
pub fn (mut app AdminApp) admin_executor_loads(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/http/executors')
	if !app.admin_authorized(ctx) { return admin_plane_forbidden(mut app, mut ctx, 'GET', req) }
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(read_executor_loads(),
		escape_unicode: true
	), {
		'admin_endpoint': 'executor_loads'
	})
}

@['/admin/http/executors'; get]
pub fn (mut app App) admin_executor_loads(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/http/executors')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', map[string]string{})
	}
	if !app.api_authorized(ctx) {
		return admin_data_plane_json(mut app, mut ctx, 'GET', req, 403, '{"error":"forbidden"}', map[string]string{})
	}
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, json.encode(read_executor_loads(),
		escape_unicode: true
	), {
		'admin_endpoint': 'executor_loads'
	})
}
