module main

import runtime_plan

// Control results are values: neither retained history nor a returned response
// shares mutable collection buffers with callers.
fn (value RuntimePlanReplacementPendingSnapshot) detached() RuntimePlanReplacementPendingSnapshot {
	return RuntimePlanReplacementPendingSnapshot{
		...value
		drain_statuses:      value.drain_statuses.clone()
		changed_pipelines:   value.changed_pipelines.clone()
		unchanged_pipelines: value.unchanged_pipelines.clone()
		drain_engines:       value.drain_engines.clone()
	}
}

fn (value RuntimePlanReplacementAttemptSnapshot) detached() RuntimePlanReplacementAttemptSnapshot {
	return RuntimePlanReplacementAttemptSnapshot{
		...value
		actions:             value.actions.map(runtime_plan.PlanReplacementAction{ kind: it.kind, targets: it.targets.clone() })
		drain_statuses:      value.drain_statuses.clone()
		changed_pipelines:   value.changed_pipelines.clone()
		unchanged_pipelines: value.unchanged_pipelines.clone()
		restart_listeners:   value.restart_listeners.clone()
		drain_engines:       value.drain_engines.clone()
		reload_transforms:   value.reload_transforms.clone()
		reload_providers:    value.reload_providers.clone()
		reload_relays:       value.reload_relays.clone()
		reasons:             value.reasons.clone()
	}
}

// Caller holds App.mu. A refresh error can only describe its captured pending.
fn (replacement &RuntimePlanReplacementRuntime) pending_for_refresh_error(generation u64, message string) RuntimePlanReplacementPendingSnapshot {
	pending := replacement.pending.detached()
	if generation != replacement.pending_generation || message == '' { return pending }
	return RuntimePlanReplacementPendingSnapshot{ ...pending, refresh_error: message }
}
