module main

import config
import crypto.sha256
import executor
import json
import os
import runtime_plan
import time
import worker

struct RuntimePlanReplacementRuntime {
mut:
	previews_total  int
	applies_total   int
	finalizes_total int
	cancels_total   int
	applied_total   int
	finalized_total int
	cancelled_total int
	draining_total  int
	rejected_total  int
	pending         RuntimePlanReplacementPendingSnapshot
	last_preview    RuntimePlanReplacementAttemptSnapshot
	last_apply      RuntimePlanReplacementAttemptSnapshot
	last_finalize   RuntimePlanReplacementAttemptSnapshot
	last_cancel     RuntimePlanReplacementAttemptSnapshot
}

struct RuntimePlanReplacementAttemptSnapshot {
	ts_unix             i64
	kind                string
	config_path         string
	status              string
	strategy            string
	allowed             bool
	applied             bool
	error               string
	actions             []runtime_plan.PlanReplacementAction
	drain_statuses      []EngineDrainStatus
	changed_pipelines   []string
	unchanged_pipelines []string
	restart_listeners   []string
	drain_engines       []string
	reload_transforms   []string
	reload_relays       []string
	reasons             []string
}

struct RuntimePlanReplacementPendingSnapshot {
pub:
	active              bool
	config_path         string
	config_hash         string
	strategy            string
	ready               bool
	created_at_unix     i64
	updated_at_unix     i64
	refresh_error       string
	drain_statuses      []EngineDrainStatus
	changed_pipelines   []string
	unchanged_pipelines []string
	drain_engines       []string
	next_schema_version int
}

struct RuntimePlanReplacementRuntimeSnapshot {
	previews_total  int
	applies_total   int
	finalizes_total int
	cancels_total   int
	applied_total   int
	finalized_total int
	cancelled_total int
	draining_total  int
	rejected_total  int
	pending         RuntimePlanReplacementPendingSnapshot
	last_preview    RuntimePlanReplacementAttemptSnapshot
	last_apply      RuntimePlanReplacementAttemptSnapshot
	last_finalize   RuntimePlanReplacementAttemptSnapshot
	last_cancel     RuntimePlanReplacementAttemptSnapshot
}

struct RuntimePlanReplacementPreview {
	config_path            string
	allowed                bool
	strategy               string
	actions                []runtime_plan.PlanReplacementAction
	unchanged_pipelines    []string
	changed_pipelines      []string
	restart_listeners      []string
	drain_engines          []string
	reload_transforms      []string
	reload_relays          []string
	reasons                []string
	current_schema_version int
	next_schema_version    int
}

struct RuntimePlanReplacementApplyResult {
	config_path string
	config_hash string
	applied     bool
	status      string
	strategy    string
	error       string
	drains      []EngineDrainStatus
	preview     RuntimePlanReplacementPreview
}

struct RuntimePlanReplacementFinalizeResult {
	config_path string
	applied     bool
	status      string
	strategy    string
	error       string
	pending     RuntimePlanReplacementPendingSnapshot
}

struct RuntimePlanReplacementCancelResult {
	cancelled bool
	status    string
	error     string
	pending   RuntimePlanReplacementPendingSnapshot
	resumed   []EngineDrainStatus
}

struct RuntimePlanReplacementPreparedRuntime {
	plan              runtime_plan.RuntimePlan
	engines           EngineRuntime
	primary_lifecycle executor.LogicExecutorLifecycle
	routes            []RuntimeRouteRule
	listener          string
}

fn (mut app App) preview_runtime_plan_replacement(config_path string) !RuntimePlanReplacementPreview {
	normalized_path := config_path.trim_space()
	if normalized_path == '' {
		return error('runtime_plan_replacement_missing_config')
	}
	next_plan := config.load_runtime_plan_file(normalized_path)!
	preview := app.preview_runtime_plan_replacement_for_plan(normalized_path, next_plan)
	app.record_runtime_plan_replacement_preview(preview)
	return preview
}

fn (mut app App) preview_runtime_plan_replacement_for_plan(config_path string, next_plan runtime_plan.RuntimePlan) RuntimePlanReplacementPreview {
	diff := runtime_plan.diff_runtime_plan_replacement(app.plan, next_plan)
	return runtime_plan_replacement_preview_from_diff(config_path, app.plan, next_plan, diff)
}

fn runtime_plan_replacement_preview_from_diff(config_path string, current_plan runtime_plan.RuntimePlan, next_plan runtime_plan.RuntimePlan, diff runtime_plan.PlanReplacementDiff) RuntimePlanReplacementPreview {
	execution := runtime_plan.execution_plan_for_replacement(diff)
	return RuntimePlanReplacementPreview{
		config_path:            config_path
		allowed:                execution.allowed
		strategy:               execution.strategy
		actions:                execution.actions
		unchanged_pipelines:    diff.unchanged_pipelines
		changed_pipelines:      diff.changed_pipelines
		restart_listeners:      diff.restart_listeners
		drain_engines:          diff.drain_engines
		reload_transforms:      diff.reload_transforms
		reload_relays:          diff.reload_relays
		reasons:                diff.reasons
		current_schema_version: current_plan.source.schema_version
		next_schema_version:    next_plan.source.schema_version
	}
}

fn runtime_plan_replacement_preview_from_pending(pending RuntimePlanReplacementPendingSnapshot) RuntimePlanReplacementPreview {
	return RuntimePlanReplacementPreview{
		config_path:         pending.config_path
		allowed:             false
		strategy:            pending.strategy
		unchanged_pipelines: pending.unchanged_pipelines
		changed_pipelines:   pending.changed_pipelines
		drain_engines:       pending.drain_engines
		next_schema_version: pending.next_schema_version
	}
}

fn runtime_plan_replacement_config_hash(config_path string) !string {
	text := os.read_file(config_path)!
	return sha256.sum(text.bytes()).hex().to_lower()
}

fn (mut app App) emit_runtime_plan_replacement_rejected(result RuntimePlanReplacementApplyResult) {
	app.emit('runtime.plan.replacement.rejected', {
		'config_path':          result.config_path
		'config_hash':          result.config_hash
		'changed_pipelines':    result.preview.changed_pipelines.join(',')
		'drain_engines':        result.preview.drain_engines.join(',')
		'error':                result.error
		'replacement_strategy': result.strategy
		'status':               result.status
	})
}

fn runtime_plan_diagnostic_codes(plan runtime_plan.RuntimePlan) string {
	mut codes := []string{}
	for diagnostic in plan.diagnostics {
		if diagnostic.code != '' && diagnostic.code !in codes {
			codes << diagnostic.code
		}
	}
	codes.sort()
	return codes.join(',')
}

fn (mut app App) emit_runtime_plan_replacement_finalize_rejected(result RuntimePlanReplacementFinalizeResult) {
	app.emit('runtime.plan.replacement.finalize_rejected', {
		'config_path':          result.config_path
		'error':                result.error
		'operation':            'finalize'
		'replacement_strategy': result.strategy
		'status':               result.status
	})
}

fn (mut app App) emit_runtime_plan_replacement_cancel_rejected(result RuntimePlanReplacementCancelResult) {
	app.emit('runtime.plan.replacement.cancel_rejected', {
		'config_path':          result.pending.config_path
		'error':                result.error
		'operation':            'cancel'
		'replacement_strategy': result.pending.strategy
		'status':               result.status
	})
}

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
	engine_build := build_engine_runtime_with_diagnostics_from_plan(app.legacy_config,
		next_executor_plan, next_plan_raw, listener_id, next_routes, app.app_build_cfg)
	mut next_plan := runtime_plan_with_projection_diagnostics(next_plan_raw)
	next_plan = runtime_plan_with_appended_diagnostics(next_plan, engine_build.diagnostics)
	relay_build := relay_runtime_with_diagnostics_from_plan(next_plan)
	next_plan = runtime_plan_with_appended_diagnostics(next_plan, relay_build.diagnostics)
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
	updated_pipelines := PipelineRuntime.new(prepared.plan, prepared.listener, prepared.routes,
		app.assets.root_real, app.pipelines.http.worker_root,
		next_engines.primary.worker_backend.env.clone(), next_engines.additional.clone())
	updated_transformers := TransformerRuntimeHub.from_plan(prepared.plan)
	updated_mcp := mcp_state_from_plan(prepared.plan, prepared.listener)
	updated_openai := openai_state_from_plan(prepared.plan, prepared.listener)
	plan_json := json.encode(prepared.plan)

	app.mu.@lock()
	app.plan = prepared.plan
	app.engines = next_engines
	app.pipelines = updated_pipelines
	app.transformers = updated_transformers
	app.protocols.runtime_plan_json = plan_json
	app.protocols.mcp = updated_mcp
	app.protocols.openai = updated_openai
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
	updated_pipelines := PipelineRuntime.new(next_plan, listener_id, routes, app.assets.root_real,
		app.pipelines.http.worker_root, primary_env, additional_workers)
	updated_transformers := TransformerRuntimeHub.from_plan(next_plan)
	updated_mcp := mcp_state_from_plan(next_plan, listener_id)
	updated_openai := openai_state_from_plan(next_plan, listener_id)
	plan_json := json.encode(next_plan)

	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	app.plan = next_plan
	app.pipelines = updated_pipelines
	app.transformers = updated_transformers
	app.protocols.runtime_plan_json = plan_json
	app.protocols.mcp = updated_mcp
	app.protocols.openai = updated_openai
}

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
