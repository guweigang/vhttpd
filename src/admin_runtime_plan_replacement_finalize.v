module main

fn (mut app App) finalize_runtime_plan_replacement() RuntimePlanReplacementFinalizeResult {
	app.begin_runtime_plan_replacement_operation() or {
		result := RuntimePlanReplacementFinalizeResult{ status: 'rejected', error: err.msg() }
		app.emit_runtime_plan_replacement_finalize_rejected(result)
		app.record_runtime_plan_replacement_finalize(result)
		return result
	}
	defer { app.end_runtime_plan_replacement_operation() }
	base := app.replacement_base_snapshot()
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
	mut prepared := app.prepare_runtime_plan_replacement_runtime(pending, base) or {
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
	publication := app.apply_prepared_runtime_plan_replacement(mut prepared) or {
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
	app.emit('runtime.plan.replaced', runtime_plan_publication_event_fields(publication, runtime_plan_replacement_preview_from_pending(pending)))
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
