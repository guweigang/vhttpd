module main

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
