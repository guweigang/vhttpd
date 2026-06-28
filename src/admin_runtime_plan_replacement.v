module main

import config
import json
import runtime_plan
import time

struct RuntimePlanReplacementRuntime {
mut:
	previews_total int
	applies_total  int
	applied_total  int
	draining_total int
	rejected_total int
	pending        RuntimePlanReplacementPendingSnapshot
	last_preview   RuntimePlanReplacementAttemptSnapshot
	last_apply     RuntimePlanReplacementAttemptSnapshot
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
	strategy            string
	ready               bool
	drain_statuses      []EngineDrainStatus
	changed_pipelines   []string
	unchanged_pipelines []string
	drain_engines       []string
	next_schema_version int
}

struct RuntimePlanReplacementRuntimeSnapshot {
	previews_total int
	applies_total  int
	applied_total  int
	draining_total int
	rejected_total int
	pending        RuntimePlanReplacementPendingSnapshot
	last_preview   RuntimePlanReplacementAttemptSnapshot
	last_apply     RuntimePlanReplacementAttemptSnapshot
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
	applied     bool
	status      string
	strategy    string
	error       string
	drains      []EngineDrainStatus
	preview     RuntimePlanReplacementPreview
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

fn (mut app App) apply_runtime_plan_replacement(config_path string) !RuntimePlanReplacementApplyResult {
	normalized_path := config_path.trim_space()
	if normalized_path == '' {
		return error('runtime_plan_replacement_missing_config')
	}
	next_plan := config.load_runtime_plan_file(normalized_path)!
	diff := runtime_plan.diff_runtime_plan_replacement(app.plan, next_plan)
	execution := runtime_plan.execution_plan_for_replacement(diff)
	preview :=
		runtime_plan_replacement_preview_from_diff(normalized_path, app.plan, next_plan, diff)
	if !execution.allowed {
		if execution.strategy == 'engine_drain_required' {
			mut drains := []EngineDrainStatus{}
			for engine_id in diff.drain_engines {
				pool := app.resolve_engine_worker_pool(engine_id)
				drains << app.drain_engine(pool)!
			}
			result := RuntimePlanReplacementApplyResult{
				config_path: normalized_path
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
			applied:     false
			status:      'rejected'
			strategy:    execution.strategy
			error:       execution.error
			preview:     preview
		}
		app.record_runtime_plan_replacement_apply(result)
		return result
	}
	app.apply_lightweight_runtime_plan(next_plan)
	app.emit('runtime.plan.replaced', {
		'config_path':          normalized_path
		'changed_pipelines':    diff.changed_pipelines.join(',')
		'unchanged_pipelines':  diff.unchanged_pipelines.join(',')
		'reload_transforms':    diff.reload_transforms.join(',')
		'replacement_allowed':  '${diff.allowed}'
		'replacement_strategy': 'lightweight'
	})
	result := RuntimePlanReplacementApplyResult{
		config_path: normalized_path
		applied:     true
		status:      'applied'
		strategy:    execution.strategy
		preview:     preview
	}
	app.record_runtime_plan_replacement_apply(result)
	return result
}

fn (mut app App) apply_lightweight_runtime_plan(next_plan runtime_plan.RuntimePlan) {
	listener_id := app.pipelines.http.listener_id
	routes := runtime_routes_from_plan(next_plan, listener_id)
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
			strategy:            result.strategy
			ready:               result.status == 'drain_ready'
			drain_statuses:      result.drains
			changed_pipelines:   result.preview.changed_pipelines
			unchanged_pipelines: result.preview.unchanged_pipelines
			drain_engines:       result.preview.drain_engines
			next_schema_version: result.preview.next_schema_version
		}
	} else {
		app.replacement.rejected_total++
	}
	app.replacement.last_apply = runtime_plan_replacement_attempt_from_preview('apply',
		result.status, result.applied, result.error, result.drains, result.preview)
}

fn (mut app App) runtime_plan_replacement_snapshot() RuntimePlanReplacementRuntimeSnapshot {
	app.refresh_pending_runtime_plan_replacement() or {}
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	return RuntimePlanReplacementRuntimeSnapshot{
		previews_total: app.replacement.previews_total
		applies_total:  app.replacement.applies_total
		applied_total:  app.replacement.applied_total
		draining_total: app.replacement.draining_total
		rejected_total: app.replacement.rejected_total
		pending:        app.replacement.pending
		last_preview:   app.replacement.last_preview
		last_apply:     app.replacement.last_apply
	}
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
		pool := app.resolve_engine_worker_pool(engine_id)
		drain_statuses << app.engine_drain_status(pool)!
	}
	ready := drain_statuses_ready(drain_statuses)
	updated := RuntimePlanReplacementPendingSnapshot{
		...pending
		ready:          ready
		drain_statuses: drain_statuses
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

fn (app &App) resolve_engine_worker_pool(engine_id string) string {
	normalized := engine_id.trim_space()
	if normalized == '' {
		return ''
	}
	if normalized in app.engines.additional {
		return normalized
	}
	tail := normalized.all_after_last('/')
	if tail != normalized && tail in app.engines.additional {
		return tail
	}
	return ''
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
