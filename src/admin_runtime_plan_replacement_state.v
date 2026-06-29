module main

import time

fn (mut app App) record_runtime_plan_replacement_preview(preview RuntimePlanReplacementPreview) {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.replacement.previews_total++
	app.replacement.last_preview = runtime_plan_replacement_attempt_from_preview('preview',
		'previewed', false, '', []EngineDrainStatus{}, preview)
}

fn (mut app App) record_runtime_plan_replacement_apply(result RuntimePlanReplacementApplyResult) {
	now := time.now().unix()
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.replacement.applies_total++
	if result.applied {
		app.replacement.applied_total++
		app.replacement.pending = RuntimePlanReplacementPendingSnapshot{}
	} else if result.status in ['draining', 'drain_ready'] {
		app.replacement.draining_total++
		app.replacement.pending = RuntimePlanReplacementPendingSnapshot{
			active:              true
			config_path:         result.config_path
			config_hash:         result.config_hash
			strategy:            result.strategy
			ready:               result.status == 'drain_ready'
			created_at_unix:     now
			updated_at_unix:     now
			drain_statuses:      result.drains
			changed_pipelines:   result.preview.changed_pipelines
			unchanged_pipelines: result.preview.unchanged_pipelines
			drain_engines:       result.preview.drain_engines
			next_schema_version: result.preview.next_schema_version
		}
	} else {
		app.replacement.rejected_total++
	}
	app.replacement.last_apply = runtime_plan_replacement_attempt_from_apply(result)
}

fn (mut app App) record_runtime_plan_replacement_finalize(result RuntimePlanReplacementFinalizeResult) {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.replacement.finalizes_total++
	if result.applied {
		app.replacement.finalized_total++
		app.replacement.applied_total++
	}
	app.replacement.last_finalize = runtime_plan_replacement_attempt_from_finalize(result)
}

fn (mut app App) record_runtime_plan_replacement_cancel(result RuntimePlanReplacementCancelResult) {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.replacement.cancels_total++
	if result.cancelled {
		app.replacement.cancelled_total++
	}
	app.replacement.last_cancel = runtime_plan_replacement_attempt_from_cancel(result)
}

fn (mut app App) runtime_plan_replacement_snapshot() RuntimePlanReplacementRuntimeSnapshot {
	mut refresh_error := ''
	app.refresh_pending_runtime_plan_replacement() or { refresh_error = err.msg() }
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	pending := if refresh_error == '' {
		app.replacement.pending
	} else {
		RuntimePlanReplacementPendingSnapshot{
			...app.replacement.pending
			refresh_error: refresh_error
		}
	}
	return RuntimePlanReplacementRuntimeSnapshot{
		previews_total:  app.replacement.previews_total
		applies_total:   app.replacement.applies_total
		finalizes_total: app.replacement.finalizes_total
		cancels_total:   app.replacement.cancels_total
		applied_total:   app.replacement.applied_total
		finalized_total: app.replacement.finalized_total
		cancelled_total: app.replacement.cancelled_total
		draining_total:  app.replacement.draining_total
		rejected_total:  app.replacement.rejected_total
		pending:         pending
		last_preview:    app.replacement.last_preview
		last_apply:      app.replacement.last_apply
		last_finalize:   app.replacement.last_finalize
		last_cancel:     app.replacement.last_cancel
	}
}

fn (mut app App) runtime_plan_replacement_pending_snapshot() RuntimePlanReplacementPendingSnapshot {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	return app.replacement.pending
}

fn (mut app App) refresh_pending_runtime_plan_replacement() !RuntimePlanReplacementPendingSnapshot {
	app.mu.@lock()
	pending := app.replacement.pending
	app.mu.unlock()
	if !pending.active {
		return pending
	}
	mut drain_statuses := []EngineDrainStatus{}
	for engine_id in pending.drain_engines {
		pool := app.resolve_engine_worker_pool(engine_id)!
		drain_statuses << app.engine_drain_status(pool)!
	}
	ready := drain_statuses_ready(drain_statuses)
	updated := RuntimePlanReplacementPendingSnapshot{
		...pending
		ready:           ready
		updated_at_unix: time.now().unix()
		drain_statuses:  drain_statuses
	}
	app.mu.@lock()
	app.replacement.pending = updated
	app.mu.unlock()
	return updated
}

fn runtime_plan_replacement_attempt_from_preview(kind string, status string, applied bool, error string, drain_statuses []EngineDrainStatus, preview RuntimePlanReplacementPreview) RuntimePlanReplacementAttemptSnapshot {
	return RuntimePlanReplacementAttemptSnapshot{
		ts_unix:             time.now().unix()
		kind:                kind
		config_path:         preview.config_path
		status:              status
		strategy:            preview.strategy
		allowed:             preview.allowed
		applied:             applied
		error:               error
		actions:             preview.actions
		drain_statuses:      drain_statuses
		changed_pipelines:   preview.changed_pipelines
		unchanged_pipelines: preview.unchanged_pipelines
		restart_listeners:   preview.restart_listeners
		drain_engines:       preview.drain_engines
		reload_transforms:   preview.reload_transforms
		reload_relays:       preview.reload_relays
		reasons:             preview.reasons
	}
}

fn runtime_plan_replacement_attempt_from_apply(result RuntimePlanReplacementApplyResult) RuntimePlanReplacementAttemptSnapshot {
	attempt := runtime_plan_replacement_attempt_from_preview('apply', result.status,
		result.applied, result.error, result.drains, result.preview)
	return RuntimePlanReplacementAttemptSnapshot{
		...attempt
		config_path: result.config_path
	}
}

fn runtime_plan_replacement_attempt_from_finalize(result RuntimePlanReplacementFinalizeResult) RuntimePlanReplacementAttemptSnapshot {
	return RuntimePlanReplacementAttemptSnapshot{
		ts_unix:             time.now().unix()
		kind:                'finalize'
		config_path:         result.config_path
		status:              result.status
		strategy:            result.strategy
		allowed:             result.applied
		applied:             result.applied
		error:               result.error
		drain_statuses:      result.pending.drain_statuses
		changed_pipelines:   result.pending.changed_pipelines
		unchanged_pipelines: result.pending.unchanged_pipelines
		drain_engines:       result.pending.drain_engines
	}
}

fn runtime_plan_replacement_attempt_from_cancel(result RuntimePlanReplacementCancelResult) RuntimePlanReplacementAttemptSnapshot {
	return RuntimePlanReplacementAttemptSnapshot{
		ts_unix:           time.now().unix()
		kind:              'cancel'
		config_path:       result.pending.config_path
		status:            result.status
		strategy:          result.pending.strategy
		allowed:           result.cancelled
		applied:           false
		error:             result.error
		drain_statuses:    result.resumed
		changed_pipelines: result.pending.changed_pipelines
		drain_engines:     result.pending.drain_engines
	}
}

fn (app &App) resolve_engine_worker_pool(engine_id string) !string {
	normalized := engine_id.trim_space()
	if normalized == '' {
		return ''
	}
	primary_kind := app.engines.primary_kind()
	if normalized == 'main' || normalized == 'primary' || normalized == primary_kind {
		return ''
	}
	if normalized in app.engines.additional {
		return normalized
	}
	tail := normalized.all_after_last('/')
	if tail != normalized && (tail == primary_kind || tail == 'primary' || tail == 'main') {
		return ''
	}
	if tail != normalized && tail in app.engines.additional {
		return tail
	}
	if app.plan.engines.len == 0 {
		return ''
	}
	if primary := app.plan.listener_fallback_engine(app.pipelines.http.listener_id) {
		primary_tail := primary.id.all_after_last('/')
		if normalized == primary.id || normalized == primary_tail {
			return ''
		}
	}
	if normalized in app.plan.engines {
		return error('runtime_plan_replacement_engine_has_no_worker_pool:${normalized}')
	}
	return error('runtime_plan_replacement_unknown_engine_pool:${normalized}')
}

fn runtime_plan_replacement_apply_status_code(result RuntimePlanReplacementApplyResult) int {
	if result.applied {
		return 200
	}
	if result.status in ['draining', 'drain_ready'] {
		return 202
	}
	return 409
}

fn runtime_plan_replacement_finalize_status_code(result RuntimePlanReplacementFinalizeResult) int {
	if result.applied {
		return 200
	}
	return 409
}

fn runtime_plan_replacement_cancel_status_code(result RuntimePlanReplacementCancelResult) int {
	if result.cancelled {
		return 200
	}
	return 409
}

fn drain_statuses_ready(statuses []EngineDrainStatus) bool {
	if statuses.len == 0 {
		return false
	}
	for status in statuses {
		if status.ready_count < status.worker_count {
			return false
		}
	}
	return true
}
