module main

import executor
import runtime_plan

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
