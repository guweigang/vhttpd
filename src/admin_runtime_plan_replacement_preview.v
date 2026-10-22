module main

import config
import runtime_plan

fn (mut app App) preview_runtime_plan_replacement(config_path string) !RuntimePlanReplacementPreview {
	normalized_path := config_path.trim_space()
	if normalized_path == '' {
		return error('runtime_plan_replacement_missing_config')
	}
	read := app.begin_replacement_preview_read()
	next_plan := config.load_runtime_plan_file(normalized_path)!
	preview := runtime_plan_replacement_preview_for_base(normalized_path, next_plan, read.base)
	app.record_replacement_preview_read(read, preview)
	return preview
}

fn (mut app App) preview_runtime_plan_replacement_for_plan(config_path string, next_plan runtime_plan.RuntimePlan) RuntimePlanReplacementPreview {
	return runtime_plan_replacement_preview_for_base(config_path, next_plan, app.replacement_base_snapshot())
}

fn runtime_plan_replacement_preview_for_base(config_path string, next_plan runtime_plan.RuntimePlan, base RuntimePlanReplacementBase) RuntimePlanReplacementPreview {
	diff := runtime_plan.diff_runtime_plan_replacement(base.plan, next_plan)
	return runtime_plan_replacement_preview_from_diff(config_path, base.plan, next_plan, diff)
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
		reload_providers:       diff.reload_providers
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
