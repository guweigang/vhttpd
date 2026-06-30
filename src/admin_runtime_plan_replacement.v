module main

import config
import executor
import runtime_plan
import worker

fn (mut app App) apply_runtime_plan_replacement(config_path string) !RuntimePlanReplacementApplyResult {
	normalized_path := config_path.trim_space()
	if normalized_path == '' {
		return error('runtime_plan_replacement_missing_config')
	}
	pending := app.runtime_plan_replacement_pending_snapshot()
	if pending.active {
		result := RuntimePlanReplacementApplyResult{
			config_path: normalized_path
			applied:     false
			status:      'rejected'
			strategy:    pending.strategy
			error:       'runtime_plan_replacement_pending_exists'
			drains:      pending.drain_statuses
			preview:     runtime_plan_replacement_preview_from_pending(pending)
		}
		app.emit_runtime_plan_replacement_rejected(result)
		app.record_runtime_plan_replacement_apply(result)
		return result
	}
	next_config_hash := runtime_plan_replacement_config_hash(normalized_path)!
	next_plan := config.load_runtime_plan_file(normalized_path)!
	diff := runtime_plan.diff_runtime_plan_replacement(app.plan, next_plan)
	execution := runtime_plan.execution_plan_for_replacement(diff)
	preview :=
		runtime_plan_replacement_preview_from_diff(normalized_path, app.plan, next_plan, diff)
	if !execution.allowed {
		if execution.strategy == 'engine_drain_required' {
			mut drains := []EngineDrainStatus{}
			for engine_id in diff.drain_engines {
				pool := app.resolve_engine_worker_pool(engine_id) or {
					result := RuntimePlanReplacementApplyResult{
						config_path: normalized_path
						config_hash: next_config_hash
						applied:     false
						status:      'rejected'
						strategy:    execution.strategy
						error:       err.msg()
						drains:      drains
						preview:     preview
					}
					app.emit_runtime_plan_replacement_rejected(result)
					app.record_runtime_plan_replacement_apply(result)
					return result
				}
				drain := app.drain_engine(pool) or {
					result := RuntimePlanReplacementApplyResult{
						config_path: normalized_path
						config_hash: next_config_hash
						applied:     false
						status:      'rejected'
						strategy:    execution.strategy
						error:       err.msg()
						drains:      drains
						preview:     preview
					}
					app.emit_runtime_plan_replacement_rejected(result)
					app.record_runtime_plan_replacement_apply(result)
					return result
				}
				drains << drain
			}
			result := RuntimePlanReplacementApplyResult{
				config_path: normalized_path
				config_hash: next_config_hash
				applied:     false
				status:      if drain_statuses_ready(drains) { 'drain_ready' } else { 'draining' }
				strategy:    execution.strategy
				drains:      drains
				preview:     preview
			}
			app.emit('runtime.plan.replacement.draining', {
				'config_path':          normalized_path
				'drain_engines':        diff.drain_engines.join(',')
				'replacement_strategy': execution.strategy
			})
			app.record_runtime_plan_replacement_apply(result)
			return result
		}
		result := RuntimePlanReplacementApplyResult{
			config_path: normalized_path
			config_hash: next_config_hash
			applied:     false
			status:      'rejected'
			strategy:    execution.strategy
			error:       execution.error
			preview:     preview
		}
		app.emit_runtime_plan_replacement_rejected(result)
		app.record_runtime_plan_replacement_apply(result)
		return result
	}
	app.apply_lightweight_runtime_plan(next_plan) or {
		result := RuntimePlanReplacementApplyResult{
			config_path: normalized_path
			config_hash: next_config_hash
			applied:     false
			status:      'rejected'
			strategy:    execution.strategy
			error:       err.msg()
			preview:     preview
		}
		app.emit_runtime_plan_replacement_rejected(result)
		app.record_runtime_plan_replacement_apply(result)
		return result
	}
	app.emit('runtime.plan.replaced', {
		'config_path':          normalized_path
		'changed_pipelines':    diff.changed_pipelines.join(',')
		'diagnostic_codes':     runtime_plan_diagnostic_codes(app.plan)
		'diagnostics_count':    '${app.plan.diagnostics.len}'
		'unchanged_pipelines':  diff.unchanged_pipelines.join(',')
		'reload_transforms':    diff.reload_transforms.join(',')
		'replacement_allowed':  '${diff.allowed}'
		'replacement_strategy': 'lightweight'
	})
	result := RuntimePlanReplacementApplyResult{
		config_path: normalized_path
		config_hash: next_config_hash
		applied:     true
		status:      'applied'
		strategy:    execution.strategy
		preview:     preview
	}
	app.record_runtime_plan_replacement_apply(result)
	return result
}

fn (mut app App) finalize_runtime_plan_replacement() RuntimePlanReplacementFinalizeResult {
	pending := app.refresh_pending_runtime_plan_replacement() or {
		result := RuntimePlanReplacementFinalizeResult{
			applied: false
			status:  'rejected'
			error:   err.msg()
		}
		app.emit_runtime_plan_replacement_finalize_rejected(result)
		app.record_runtime_plan_replacement_finalize(result)
		return result
	}
	if !pending.active {
		result := RuntimePlanReplacementFinalizeResult{
			applied: false
			status:  'rejected'
			error:   'runtime_plan_replacement_no_pending'
		}
		app.emit_runtime_plan_replacement_finalize_rejected(result)
		app.record_runtime_plan_replacement_finalize(result)
		return result
	}
	if !pending.ready {
		mut inflight_requests := i64(0)
		for drain_status in pending.drain_statuses {
			inflight_requests += drain_status.inflight_requests
		}
		result := RuntimePlanReplacementFinalizeResult{
			config_path: pending.config_path
			applied:     false
			status:      'waiting_for_drain'
			strategy:    pending.strategy
			error:       'runtime_plan_replacement_drain_not_ready'
			pending:     pending
		}
		app.emit('runtime.plan.replacement.finalize_waiting', {
			'config_path':          pending.config_path
			'drain_engines':        pending.drain_engines.join(',')
			'inflight_requests':    '${inflight_requests}'
			'replacement_strategy': pending.strategy
		})
		app.record_runtime_plan_replacement_finalize(result)
		return result
	}
	mut prepared := app.prepare_runtime_plan_replacement_runtime(pending) or {
		result := RuntimePlanReplacementFinalizeResult{
			config_path: pending.config_path
			applied:     false
			status:      'rejected'
			strategy:    pending.strategy
			error:       err.msg()
			pending:     pending
		}
		app.emit_runtime_plan_replacement_finalize_rejected(result)
		app.record_runtime_plan_replacement_finalize(result)
		return result
	}
	app.apply_prepared_runtime_plan_replacement(mut prepared) or {
		result := RuntimePlanReplacementFinalizeResult{
			config_path: pending.config_path
			applied:     false
			status:      'rejected'
			strategy:    pending.strategy
			error:       err.msg()
			pending:     pending
		}
		app.emit_runtime_plan_replacement_finalize_rejected(result)
		app.record_runtime_plan_replacement_finalize(result)
		return result
	}
	app.emit('runtime.plan.replaced', {
		'config_path':          pending.config_path
		'changed_pipelines':    pending.changed_pipelines.join(',')
		'diagnostic_codes':     runtime_plan_diagnostic_codes(prepared.plan)
		'diagnostics_count':    '${prepared.plan.diagnostics.len}'
		'unchanged_pipelines':  pending.unchanged_pipelines.join(',')
		'drain_engines':        pending.drain_engines.join(',')
		'replacement_strategy': pending.strategy
	})
	result := RuntimePlanReplacementFinalizeResult{
		config_path: pending.config_path
		applied:     true
		status:      'applied'
		strategy:    pending.strategy
		pending:     pending
	}
	app.record_runtime_plan_replacement_finalize(result)
	return result
}

fn (mut app App) cancel_runtime_plan_replacement() RuntimePlanReplacementCancelResult {
	app.mu.@lock()
	pending := app.replacement.pending
	app.mu.unlock()
	if !pending.active {
		result := RuntimePlanReplacementCancelResult{
			cancelled: false
			status:    'rejected'
			error:     'runtime_plan_replacement_no_pending'
		}
		app.emit_runtime_plan_replacement_cancel_rejected(result)
		app.record_runtime_plan_replacement_cancel(result)
		return result
	}
	mut resumed := []EngineDrainStatus{}
	for engine_id in pending.drain_engines {
		pool := app.resolve_engine_worker_pool(engine_id) or {
			result := RuntimePlanReplacementCancelResult{
				cancelled: false
				status:    'rejected'
				error:     err.msg()
				pending:   pending
				resumed:   resumed
			}
			app.emit_runtime_plan_replacement_cancel_rejected(result)
			app.record_runtime_plan_replacement_cancel(result)
			return result
		}
		status := app.resume_engine(pool) or {
			result := RuntimePlanReplacementCancelResult{
				cancelled: false
				status:    'rejected'
				error:     err.msg()
				pending:   pending
				resumed:   resumed
			}
			app.emit_runtime_plan_replacement_cancel_rejected(result)
			app.record_runtime_plan_replacement_cancel(result)
			return result
		}
		resumed << status
	}
	app.mu.@lock()
	app.replacement.pending = RuntimePlanReplacementPendingSnapshot{}
	app.mu.unlock()
	app.emit('runtime.plan.replacement.cancelled', {
		'config_path':          pending.config_path
		'drain_engines':        pending.drain_engines.join(',')
		'replacement_strategy': pending.strategy
	})
	result := RuntimePlanReplacementCancelResult{
		cancelled: true
		status:    'cancelled'
		pending:   pending
		resumed:   resumed
	}
	app.record_runtime_plan_replacement_cancel(result)
	return result
}

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
		next_engines.primary.worker_backend.env.clone(), next_engines.additional.clone())

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
		app.assets.root_real, app.pipelines.http.worker_root, primary_env, additional_workers)

	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.apply_runtime_plan_runtime_projection(next_plan, projection)
}
