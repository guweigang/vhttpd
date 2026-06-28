module main

import config
import json
import runtime_plan

struct RuntimePlanReplacementPreview {
	config_path            string
	allowed                bool
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
	error       string
	preview     RuntimePlanReplacementPreview
}

fn (mut app App) preview_runtime_plan_replacement(config_path string) !RuntimePlanReplacementPreview {
	normalized_path := config_path.trim_space()
	if normalized_path == '' {
		return error('runtime_plan_replacement_missing_config')
	}
	next_plan := config.load_runtime_plan_file(normalized_path)!
	return app.preview_runtime_plan_replacement_for_plan(normalized_path, next_plan)
}

fn (mut app App) preview_runtime_plan_replacement_for_plan(config_path string, next_plan runtime_plan.RuntimePlan) RuntimePlanReplacementPreview {
	diff := runtime_plan.diff_runtime_plan_replacement(app.plan, next_plan)
	return runtime_plan_replacement_preview_from_diff(config_path, app.plan, next_plan, diff)
}

fn runtime_plan_replacement_preview_from_diff(config_path string, current_plan runtime_plan.RuntimePlan, next_plan runtime_plan.RuntimePlan, diff runtime_plan.PlanReplacementDiff) RuntimePlanReplacementPreview {
	return RuntimePlanReplacementPreview{
		config_path:            config_path
		allowed:                diff.allowed
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
	preview :=
		runtime_plan_replacement_preview_from_diff(normalized_path, app.plan, next_plan, diff)
	if !diff.allowed {
		return RuntimePlanReplacementApplyResult{
			config_path: normalized_path
			applied:     false
			status:      'rejected'
			error:       'runtime_plan_replacement_unsafe'
			preview:     preview
		}
	}
	if diff.restart_listeners.len > 0 {
		return RuntimePlanReplacementApplyResult{
			config_path: normalized_path
			applied:     false
			status:      'rejected'
			error:       'runtime_plan_replacement_requires_listener_restart'
			preview:     preview
		}
	}
	if diff.drain_engines.len > 0 {
		return RuntimePlanReplacementApplyResult{
			config_path: normalized_path
			applied:     false
			status:      'rejected'
			error:       'runtime_plan_replacement_requires_engine_drain'
			preview:     preview
		}
	}
	if diff.reload_relays.len > 0 {
		return RuntimePlanReplacementApplyResult{
			config_path: normalized_path
			applied:     false
			status:      'rejected'
			error:       'runtime_plan_replacement_requires_relay_reload'
			preview:     preview
		}
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
	return RuntimePlanReplacementApplyResult{
		config_path: normalized_path
		applied:     true
		status:      'applied'
		preview:     preview
	}
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
