module main

import config
import dispatch
import executor
import runtime_plan
import server_lifecycle

fn runtime_plan_with_runtime_diagnostics(cfg config.VhttpdConfig, executor_plan executor.LogicExecutorRuntimePlan, plan runtime_plan.RuntimePlan, listener_id string, routes []RuntimeRouteRule, build_cfg server_lifecycle.AppRuntimeBuildConfig) runtime_plan.RuntimePlan {
	mut runtime_visible_plan := runtime_plan_with_projection_diagnostics(plan)
	runtime_visible_plan = runtime_plan_with_appended_diagnostics(runtime_visible_plan, runtime_route_projection_diagnostics(runtime_visible_plan,
		listener_id))
	runtime_visible_plan = runtime_plan_with_appended_diagnostics(runtime_visible_plan, protocol_runtime_diagnostics_from_plan(runtime_visible_plan,
		listener_id))
	engine_build := build_engine_runtime_with_diagnostics_from_plan(cfg, executor_plan,
		runtime_visible_plan, listener_id, routes, build_cfg)
	runtime_visible_plan = runtime_plan_with_appended_diagnostics(runtime_visible_plan,
		engine_build.diagnostics)
	relay_build := relay_runtime_with_diagnostics_from_plan(runtime_visible_plan)
	return runtime_plan_with_appended_diagnostics(runtime_visible_plan, relay_build.diagnostics)
}

fn runtime_plan_with_appended_diagnostics(plan runtime_plan.RuntimePlan, diagnostics []runtime_plan.PlanDiagnostic) runtime_plan.RuntimePlan {
	if diagnostics.len == 0 {
		return plan
	}
	return runtime_plan.RuntimePlan{
		...plan
		diagnostics: runtime_plan_append_unique_diagnostics(plan.diagnostics, diagnostics)
	}
}

fn runtime_plan_with_projection_diagnostics(plan runtime_plan.RuntimePlan) runtime_plan.RuntimePlan {
	projection_diagnostics := dispatch.runtime_plan_projection_diagnostics(plan)
	if projection_diagnostics.len == 0 {
		return plan
	}
	diagnostics := runtime_plan_append_unique_diagnostics(plan.diagnostics, projection_diagnostics)
	return runtime_plan.RuntimePlan{
		...plan
		diagnostics: diagnostics
	}
}

fn runtime_plan_append_unique_diagnostics(existing []runtime_plan.PlanDiagnostic, additions []runtime_plan.PlanDiagnostic) []runtime_plan.PlanDiagnostic {
	mut diagnostics := []runtime_plan.PlanDiagnostic{cap: existing.len + additions.len}
	mut seen := map[string]bool{}
	for diagnostic in existing {
		key := runtime_plan_diagnostic_key(diagnostic)
		if seen[key] {
			continue
		}
		seen[key] = true
		diagnostics << diagnostic
	}
	for diagnostic in additions {
		key := runtime_plan_diagnostic_key(diagnostic)
		if seen[key] {
			continue
		}
		seen[key] = true
		diagnostics << diagnostic
	}
	return diagnostics
}

fn runtime_plan_diagnostic_key(diagnostic runtime_plan.PlanDiagnostic) string {
	return '${diagnostic.severity}\n${diagnostic.code}\n${diagnostic.path}\n${diagnostic.message}'
}
