module main

import worker
import config
import runtime_plan

fn (mut app App) apply_runtime_plan_replacement(config_path string) !RuntimePlanReplacementApplyResult {
	normalized_path := config_path.trim_space()
	if normalized_path == '' {
		return error('runtime_plan_replacement_missing_config')
	}
	app.begin_runtime_plan_replacement_operation() or {
		result := RuntimePlanReplacementApplyResult{ config_path: normalized_path, status: 'rejected', error: err.msg() }
		app.emit_runtime_plan_replacement_rejected(result)
		app.record_runtime_plan_replacement_apply(result)
		return result
	}
	defer { app.end_runtime_plan_replacement_operation() }
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
	base := app.replacement_base_snapshot()
	current_plan := base.plan
	diff := runtime_plan.diff_runtime_plan_replacement(current_plan, next_plan)
	execution := runtime_plan.execution_plan_for_replacement(diff)
	preview :=
		runtime_plan_replacement_preview_from_diff(normalized_path, current_plan, next_plan, diff)
	if !execution.allowed {
		if execution.strategy == 'engine_drain_required' {
			mut drains := []worker.DrainStatus{}
			pools := app.replacement_worker_pools(diff.drain_engines) or {
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
			for pool in pools {
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
	publication := app.apply_lightweight_runtime_plan_from_base(next_plan, base) or {
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
	app.emit('runtime.plan.replaced', runtime_plan_publication_event_fields(publication, preview))
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
