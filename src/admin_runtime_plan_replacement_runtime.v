module main

import config
import executor
import runtime_plan
import worker

fn (mut app App) prepare_runtime_plan_replacement_runtime(pending RuntimePlanReplacementPendingSnapshot, base RuntimePlanReplacementBase) !RuntimePlanReplacementPreparedRuntime {
	if !pending.active {
		return error('runtime_plan_replacement_no_pending')
	}
	current_hash := runtime_plan_replacement_config_hash(pending.config_path)!
	if pending.config_hash != '' && current_hash != pending.config_hash {
		return error('runtime_plan_replacement_config_changed')
	}
	next_plan_raw := config.load_runtime_plan_file(pending.config_path)!
	listener_id := base.listener
	next_routes := runtime_routes_from_plan(next_plan_raw, listener_id)
	next_executor_plan := executor.LogicExecutorRuntimePlan.resolve_from_plan([]string{},
		base.legacy, next_plan_raw, listener_id)!
	next_plan := runtime_plan_with_runtime_diagnostics(base.legacy, next_executor_plan,
		next_plan_raw, listener_id, next_routes, base.build)
	engine_build := build_engine_runtime_with_diagnostics_from_plan(base.legacy,
		next_executor_plan, next_plan, listener_id, next_routes, base.build)
	return RuntimePlanReplacementPreparedRuntime{
		base_generation:   base.generation
		scheme:            base.scheme
		plan:              next_plan
		engines:           engine_build.runtime
		primary_lifecycle: next_executor_plan.lifecycle
		routes:            next_routes
		listener:          listener_id
	}
}

fn (mut app App) apply_prepared_runtime_plan_replacement(mut prepared RuntimePlanReplacementPreparedRuntime) !RuntimePlanPublication {
	// Replacement startup, publication and retirement belong to the App's
	// accepted lifecycle work. Shutdown closes admission and joins this scope.
	if !app.lifecycle.shutdown.begin_start() {
		return error('runtime_plan_replacement_app_stopping')
	}
	defer { app.lifecycle.shutdown.end_start() }

	mut next_engines := prepared.engines
	scheme := prepared.scheme or { app.replacement_base_snapshot().scheme }
	apply_runtime_scheme_to_engine_runtime(mut next_engines, scheme)
	port := app.build_engine_lifecycle_port()
	mut facade := app.as_facade()
	next_engines.start(prepared.primary_lifecycle, port, mut facade)
	validate_replacement_engine_runtime_ready(next_engines) or {
		next_engines.stop(prepared.primary_lifecycle, port)
		return err
	}
	app.mu.@lock()
	if expected := prepared.base_generation {
		if expected != app.replacement.plan_generation {
			app.mu.unlock()
			next_engines.stop(prepared.primary_lifecycle, port)
			return error('runtime_plan_replacement_stale_base')
		}
	}
	projection := RuntimePlanRuntimeProjection.from_plan(prepared.plan, prepared.listener,
		prepared.routes, app.assets.root_real, app.pipelines.http.worker_root,
		next_engines.primary.env_snapshot(), next_engines.additional.clone(),
		app.provider_runtime_settings_snapshot())

	// Capture precisely the generation replaced by this publication.
	mut old_engines := app.engines
	app.engines = next_engines
	retirement := app.apply_runtime_plan_runtime_projection(prepared.plan, projection)
	app.replacement.clear_pending()
	publication := RuntimePlanPublication{ generation: app.replacement.plan_generation, plan: prepared.plan }
	app.mu.unlock()

	app.protocols.plugins.finish_retirement(retirement)
	old_primary_lifecycle := engine_primary_lifecycle_or_disabled(old_engines)
	old_engines.stop(old_primary_lifecycle, port)
	app.retire_mcp_dispatch_sessions()
	return publication
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
		validate_replacement_worker_state_ready(name, state)!
	}
}

fn validate_replacement_worker_state_ready(kind string, state &worker.WorkerState) ! {
	if state.worker_backend_mode == .disabled {
		return
	}
	if state.worker_backend.sockets.len == 0 {
		return error('runtime_plan_replacement_worker_sockets_empty:${kind}')
	}
	if !state.worker_backend.autostart {
		return
	}
	diagnostics := state.selection_diagnostics()
	if diagnostics.any(it.probe_error == '') {
		return
	}
	return error('runtime_plan_replacement_engine_not_ready:${kind}')
}

fn (mut app App) apply_lightweight_runtime_plan(next_plan_raw runtime_plan.RuntimePlan) !RuntimePlanPublication {
	return app.apply_lightweight_runtime_plan_from_base(next_plan_raw, app.replacement_base_snapshot())
}

fn (mut app App) apply_lightweight_runtime_plan_from_base(next_plan_raw runtime_plan.RuntimePlan, base RuntimePlanReplacementBase) !RuntimePlanPublication {
	// Replacement startup, publication and retirement belong to the App's
	// accepted lifecycle work. Shutdown closes admission and joins this scope.
	if !app.lifecycle.shutdown.begin_start() {
		return error('runtime_plan_replacement_app_stopping')
	}
	defer { app.lifecycle.shutdown.end_start() }

	listener_id := base.listener
	routes := runtime_routes_from_plan(next_plan_raw, listener_id)
	next_executor_plan := executor.LogicExecutorRuntimePlan.resolve_from_plan([]string{},
		base.legacy, next_plan_raw, listener_id)!
	next_plan := runtime_plan_with_runtime_diagnostics(base.legacy, next_executor_plan,
		next_plan_raw, listener_id, routes, base.build)
	app.mu.@lock()
	if base.generation != app.replacement.plan_generation {
		app.mu.unlock()
		return error('runtime_plan_replacement_stale_base')
	}
	primary_env := app.engines.primary.env_snapshot()
	additional_workers := app.engines.additional.clone()
	projection := RuntimePlanRuntimeProjection.from_plan(next_plan, listener_id, routes,
		app.assets.root_real, app.pipelines.http.worker_root, primary_env, additional_workers,
		app.provider_runtime_settings_snapshot())

	retirement := app.apply_runtime_plan_runtime_projection(next_plan, projection)
	publication := RuntimePlanPublication{ generation: app.replacement.plan_generation, plan: next_plan }
	app.mu.unlock()
	app.protocols.plugins.finish_retirement(retirement)
	return publication
}
