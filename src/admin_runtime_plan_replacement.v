module main

import config
import runtime_plan

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
