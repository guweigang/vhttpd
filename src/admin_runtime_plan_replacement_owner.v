module main

// Mutating admin operations own one complete workflow, including drain/resume,
// publication, retirement and result recording. Never hold App.mu over callbacks.
fn (mut app App) begin_runtime_plan_replacement_operation() ! {
	if !app.lifecycle.shutdown.begin_start() {
		return error('runtime_plan_replacement_app_stopping')
	}
	app.mu.@lock()
	if app.replacement.operation_active {
		app.mu.unlock()
		app.lifecycle.shutdown.end_start()
		return error('runtime_plan_replacement_busy')
	}
	app.replacement.operation_active = true
	app.mu.unlock()
}

fn (mut app App) end_runtime_plan_replacement_operation() {
	app.mu.@lock()
	app.replacement.operation_active = false
	app.mu.unlock()
	app.lifecycle.shutdown.end_start()
}

// Caller holds App.mu. Invalidates every previously captured refresh snapshot.
fn (mut replacement RuntimePlanReplacementRuntime) clear_pending() {
	replacement.pending_generation++
	replacement.pending = RuntimePlanReplacementPendingSnapshot{}
}

fn (mut app App) publish_pending_runtime_plan_refresh(generation u64, updated RuntimePlanReplacementPendingSnapshot) RuntimePlanReplacementPendingSnapshot {
	app.mu.@lock()
	defer { app.mu.unlock() }
	if app.replacement.pending_generation == generation {
		app.replacement.pending = updated.detached()
	}
	return app.replacement.pending.detached()
}

// Caller holds App.mu; the published plan is immutable after publication.
fn (app &App) replacement_base_unlocked() RuntimePlanReplacementBase {
	return RuntimePlanReplacementBase{
		generation: app.replacement.plan_generation
		plan:       app.plan
		listener:   app.pipelines.http.listener_id
		scheme:     app.lifecycle.data_plane_scheme
		legacy:     app.legacy_config
		build:      app.app_build_cfg
	}
}

fn (app &App) replacement_base_snapshot() RuntimePlanReplacementBase {
	app.mu.@lock()
	defer { app.mu.unlock() }
	return app.replacement_base_unlocked()
}

fn (mut app App) begin_replacement_preview_read() RuntimePlanPreviewRead {
	app.mu.@lock()
	defer { app.mu.unlock() }
	app.replacement.preview_sequence++
	return RuntimePlanPreviewRead{ sequence: app.replacement.preview_sequence, base: app.replacement_base_unlocked() }
}

fn (mut app App) record_replacement_preview_read(read RuntimePlanPreviewRead, preview RuntimePlanReplacementPreview) {
	app.mu.@lock()
	defer { app.mu.unlock() }
	app.replacement.previews_total++
	if read.base.generation != app.replacement.plan_generation || read.sequence < app.replacement.last_preview_sequence {
		return
	}
	app.replacement.last_preview_sequence = read.sequence
	app.replacement.last_preview = runtime_plan_replacement_attempt_from_preview('preview', 'previewed', false, '', [], preview).detached()
}
