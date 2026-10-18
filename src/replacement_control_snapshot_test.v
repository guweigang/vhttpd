module main

import runtime_plan
import executor
import worker

fn control_plan(label string, schema int) runtime_plan.RuntimePlan {
	return runtime_plan.RuntimePlan{ source: runtime_plan.PlanSource{ config_path: label, schema_version: schema }, diagnostics: [runtime_plan.PlanDiagnostic{ code: label }] }
}

fn control_publish(mut app App, label string, schema int) RuntimePlanPublication {
	plan := control_plan(label, schema)
	app.mu.@lock()
	retirement := app.apply_runtime_plan_runtime_projection(plan, RuntimePlanRuntimeProjection{})
	publication := RuntimePlanPublication{ generation: app.replacement.plan_generation, plan: plan }
	app.mu.unlock()
	app.protocols.plugins.finish_retirement(retirement)
	return publication
}

fn control_preview(label string) RuntimePlanReplacementPreview {
	return RuntimePlanReplacementPreview{ config_path: label, strategy: 'lightweight', allowed: true, changed_pipelines: ['changed'], unchanged_pipelines: ['same'], reload_transforms: ['transform'] }
}

fn test_older_preview_completion_cannot_replace_newer_preview_record() {
	mut app := &App{}
	first := app.begin_replacement_preview_read()
	second := app.begin_replacement_preview_read()
	app.record_replacement_preview_read(second, control_preview('second'))
	app.record_replacement_preview_read(first, control_preview('first'))
	assert app.runtime_plan_replacement_snapshot().last_preview.config_path == 'second'
	assert app.replacement.previews_total == 2
}

fn test_preview_from_old_publication_cannot_publish_into_new_history() {
	mut app := &App{}
	old := app.begin_replacement_preview_read()
	control_publish(mut app, 'new', 4)
	current := app.begin_replacement_preview_read()
	app.record_replacement_preview_read(current, control_preview('current'))
	app.record_replacement_preview_read(old, control_preview('obsolete'))
	assert app.runtime_plan_replacement_snapshot().last_preview.config_path == 'current'
	assert app.replacement.previews_total == 2
}

fn test_preview_schema_and_diff_use_the_captured_base() {
	mut app := &App{}
	control_publish(mut app, 'old', 3)
	read := app.begin_replacement_preview_read()
	control_publish(mut app, 'current', 4)
	preview := runtime_plan_replacement_preview_for_base('requested', control_plan('next', 9), read.base)
	assert preview.current_schema_version == 3
	assert preview.next_schema_version == 9
	assert preview.config_path == 'requested'
	assert app.admin_plan_view().plan.source.schema_version == 4
}

fn test_lightweight_apply_rejects_a_stale_compilation_base() {
	mut app := &App{}
	base := app.replacement_base_snapshot()
	control_publish(mut app, 'winner', 4)
	if _ := app.apply_lightweight_runtime_plan_from_base(control_plan('obsolete', 3), base) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_replacement_stale_base'
	}
	assert app.admin_plan_view().plan.source.config_path == 'winner'
	assert app.admin_plan_view().generation == 1
	assert !app.replacement.operation_active
}

struct ControlCallbackExecutor {
	executor.DisabledLogicExecutor
	warmup_fn fn () @[required]
	close_fn  fn () @[required]
}

fn (e ControlCallbackExecutor) warmup(mut _ executor.AppFacade) ! { e.warmup_fn() }

fn (e ControlCallbackExecutor) close() { e.close_fn() }

fn control_noop() {}

fn test_publication_receipt_and_events_survive_reentrant_retirement() {
	mut app := &App{}
	app.engines.primary.logic_executor = ControlCallbackExecutor{
		warmup_fn: control_noop
		close_fn:  fn [mut app] () { control_publish(mut app, 'later', 5) }
	}
	mut prepared := RuntimePlanReplacementPreparedRuntime{
		base_generation:   u64(0)
		scheme:            'http'
		plan:              control_plan('committed', 4)
		engines:           EngineRuntime{ primary: &worker.WorkerState{ worker_backend_mode: .disabled, logic_executor: executor.DisabledLogicExecutor{} } }
		primary_lifecycle: executor.disabled_executor_lifecycle()
	}
	receipt := app.apply_prepared_runtime_plan_replacement(mut prepared) or { panic(err) }
	assert receipt.generation == 1
	assert app.admin_plan_view().generation == 2
	assert app.admin_plan_view().plan.source.config_path == 'later'
	fields := runtime_plan_publication_event_fields(receipt, control_preview('request'))
	assert fields['config_path'] == 'request'
	assert fields['diagnostic_codes'] == 'committed'
	assert fields['diagnostics_count'] == '1'
	assert fields['replacement_allowed'] == 'true'
	assert fields['reload_transforms'] == 'transform'
	drained := runtime_plan_publication_event_fields(receipt, RuntimePlanReplacementPreview{ config_path: 'request', strategy: 'engine_drain_required', drain_engines: ['main'] })
	assert drained['diagnostic_codes'] == 'committed'
	assert drained['drain_engines'] == 'main'
	assert 'replacement_allowed' !in drained
	assert 'reload_transforms' !in drained
}

@[heap]
struct ControlCloseCounts {
mut:
	old       int
	candidate int
}

fn test_prepared_conflict_retires_candidate_and_preserves_published_engine() {
	mut counts := &ControlCloseCounts{}
	mut app := &App{}
	old := &worker.WorkerState{
		worker_backend_mode: .disabled
		logic_executor:      ControlCallbackExecutor{
			warmup_fn: control_noop
			close_fn:  fn [mut counts] () {
				counts.old++
			}
		}
	}
	app.engines = EngineRuntime{ primary: old }
	mut prepared := RuntimePlanReplacementPreparedRuntime{
		base_generation:   u64(0)
		plan:              control_plan('obsolete', 3)
		engines:           EngineRuntime{
			primary: &worker.WorkerState{
				worker_backend_mode: .disabled
				logic_executor:      ControlCallbackExecutor{
					warmup_fn: fn [mut app] () { control_publish(mut app, 'winner', 4) }
					close_fn:  fn [mut counts] () { counts.candidate++ }
				}
			}
		}
		primary_lifecycle: executor.disabled_executor_lifecycle()
	}
	if _ := app.apply_prepared_runtime_plan_replacement(mut prepared) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_replacement_stale_base'
	}
	assert counts.old == 0
	assert counts.candidate == 1
	assert voidptr(app.engines.primary) == voidptr(old)
	assert app.admin_plan_view().plan.source.config_path == 'winner'
	app.lifecycle.shutdown.wait_started()
}

fn control_pending_result(label string) RuntimePlanReplacementApplyResult {
	return RuntimePlanReplacementApplyResult{ config_path: label, status: 'drain_ready', strategy: 'engine_drain_required', preview: RuntimePlanReplacementPreview{ changed_pipelines: ['changed'], unchanged_pipelines: ['same'], actions: [runtime_plan.PlanReplacementAction{ kind: 'reload', targets: ['target'] }] } }
}

fn test_history_and_pending_do_not_alias_the_control_result() {
	mut app := &App{}
	result := control_pending_result('request')
	app.record_runtime_plan_replacement_apply(result)
	// Deliberately alias fixture buffers to test detachment at the write boundary.
	mut changed := unsafe { result.preview.changed_pipelines }
	mut same := unsafe { result.preview.unchanged_pipelines }
	mut targets := unsafe { result.preview.actions[0].targets }
	changed[0] = 'poison'
	same[0] = 'poison'
	targets[0] = 'poison'
	snapshot := app.runtime_plan_replacement_snapshot()
	assert snapshot.pending.changed_pipelines == ['changed']
	assert snapshot.pending.unchanged_pipelines == ['same']
	assert snapshot.last_apply.actions[0].targets == ['target']
}

fn test_returned_history_and_refresh_values_are_detached() {
	mut app := &App{}
	app.record_runtime_plan_replacement_apply(control_pending_result('request'))
	snapshot := app.runtime_plan_replacement_snapshot()
	mut returned := unsafe { snapshot.last_apply.actions[0].targets }
	returned[0] = 'poison'
	pending := app.runtime_plan_replacement_pending_snapshot()
	updated := app.publish_pending_runtime_plan_refresh(app.replacement.pending_generation, pending)
	mut changed := unsafe { updated.changed_pipelines }
	changed[0] = 'poison'
	assert app.runtime_plan_replacement_snapshot().last_apply.actions[0].targets == ['target']
	assert app.runtime_plan_replacement_pending_snapshot().changed_pipelines == ['changed']
}

fn test_refresh_error_cannot_be_attached_to_another_pending_generation() {
	mut app := &App{}
	app.record_runtime_plan_replacement_apply(control_pending_result('first'))
	generation := app.replacement.pending_generation
	app.record_runtime_plan_replacement_apply(control_pending_result('second'))
	stale := app.replacement.pending_for_refresh_error(generation, 'old-error')
	assert stale.config_path == 'second'
	assert stale.refresh_error == ''
	current := app.replacement.pending_for_refresh_error(app.replacement.pending_generation, 'current-error')
	assert current.refresh_error == 'current-error'
	assert app.replacement.pending.refresh_error == ''
}
