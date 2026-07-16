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
