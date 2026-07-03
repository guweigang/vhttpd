module main

import config
import executor
import runtime_plan
import worker

fn (mut app App) prepare_runtime_plan_replacement_runtime(pending RuntimePlanReplacementPendingSnapshot) !RuntimePlanReplacementPreparedRuntime {
	if !pending.active {
		return error('runtime_plan_replacement_no_pending')
	}
	current_hash := runtime_plan_replacement_config_hash(pending.config_path)!
	if pending.config_hash != '' && current_hash != pending.config_hash {
		return error('runtime_plan_replacement_config_changed')
	}
	next_plan_raw := config.load_runtime_plan_file(pending.config_path)!
	listener_id := app.pipelines.http.listener_id
	next_routes := runtime_routes_from_plan(next_plan_raw, listener_id)
	next_executor_plan := executor.LogicExecutorRuntimePlan.resolve_from_plan([]string{},
		app.legacy_config, next_plan_raw, listener_id)!
	next_plan := runtime_plan_with_runtime_diagnostics(app.legacy_config, next_executor_plan,
		next_plan_raw, listener_id, next_routes, app.app_build_cfg)
	engine_build := build_engine_runtime_with_diagnostics_from_plan(app.legacy_config,
		next_executor_plan, next_plan, listener_id, next_routes, app.app_build_cfg)
	return RuntimePlanReplacementPreparedRuntime{
		plan:              next_plan
		engines:           engine_build.runtime
		primary_lifecycle: next_executor_plan.lifecycle
		routes:            next_routes
		listener:          listener_id
	}
}

fn (mut app App) apply_prepared_runtime_plan_replacement(mut prepared RuntimePlanReplacementPreparedRuntime) ! {
	mut next_engines := prepared.engines
	apply_runtime_scheme_to_engine_runtime(mut next_engines, app.lifecycle.data_plane_scheme)
	port := app.build_engine_lifecycle_port()
	mut facade := app.as_facade()
	next_engines.start(prepared.primary_lifecycle, port, mut facade)
	validate_replacement_engine_runtime_ready(next_engines) or {
		next_engines.stop(prepared.primary_lifecycle, port)
		return err
	}
	mut old_engines := app.engines
	old_primary_lifecycle := engine_primary_lifecycle_or_disabled(old_engines)
	projection := RuntimePlanRuntimeProjection.from_plan(prepared.plan, prepared.listener,
		prepared.routes, app.assets.root_real, app.pipelines.http.worker_root,
		next_engines.primary.worker_backend.env.clone(), next_engines.additional.clone(),
		app.provider_runtime_settings_snapshot())

	app.mu.@lock()
	app.engines = next_engines
	app.apply_runtime_plan_runtime_projection(prepared.plan, projection)
	app.replacement.pending = RuntimePlanReplacementPendingSnapshot{}
	app.mu.unlock()

	old_engines.stop(old_primary_lifecycle, port)
}

fn engine_primary_lifecycle_or_disabled(engines EngineRuntime) executor.LogicExecutorLifecycle {
	spec := executor.builtin_executor_spec_find(engines.primary_kind()) or {
		return executor.disabled_executor_lifecycle()
	}
	return spec.lifecycle
}

fn validate_replacement_engine_runtime_ready(engines EngineRuntime) ! {
	validate_replacement_worker_state_ready('main', engines.primary)!
	for name, state in engines.additional {
		validate_replacement_worker_state_ready(name, *state)!
	}
}

fn validate_replacement_worker_state_ready(kind string, state worker.WorkerState) ! {
	if state.worker_backend_mode == .disabled {
		return
	}
	if state.worker_backend.sockets.len == 0 {
		return error('runtime_plan_replacement_worker_sockets_empty:${kind}')
	}
	if !state.worker_backend.autostart {
		return
	}
	diagnostics := worker_selection_diagnostics_for_state(state)
	if diagnostics.any(it.probe_error == '') {
		return
	}
	return error('runtime_plan_replacement_engine_not_ready:${kind}')
}

fn (mut app App) apply_lightweight_runtime_plan(next_plan_raw runtime_plan.RuntimePlan) ! {
	listener_id := app.pipelines.http.listener_id
	routes := runtime_routes_from_plan(next_plan_raw, listener_id)
	next_executor_plan := executor.LogicExecutorRuntimePlan.resolve_from_plan([]string{},
		app.legacy_config, next_plan_raw, listener_id)!
	next_plan := runtime_plan_with_runtime_diagnostics(app.legacy_config, next_executor_plan,
		next_plan_raw, listener_id, routes, app.app_build_cfg)
	primary_env := app.engines.primary.worker_backend.env.clone()
	additional_workers := app.engines.additional.clone()
	projection := RuntimePlanRuntimeProjection.from_plan(next_plan, listener_id, routes,
		app.assets.root_real, app.pipelines.http.worker_root, primary_env, additional_workers,
		app.provider_runtime_settings_snapshot())

	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.apply_runtime_plan_runtime_projection(next_plan, projection)
}
