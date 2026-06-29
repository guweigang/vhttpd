module main

import runtime_plan
import worker

struct RuntimePlanRuntimeProjection {
	pipelines       PipelineRuntime
	transformers    TransformerRuntimeHub
	protocol_update ProtocolRuntimePlanUpdate
}

fn RuntimePlanRuntimeProjection.from_plan(plan runtime_plan.RuntimePlan, listener_id string, routes []RuntimeRouteRule, assets_root string, worker_root string, primary_env map[string]string, additional_workers map[string]&worker.WorkerState) RuntimePlanRuntimeProjection {
	return RuntimePlanRuntimeProjection{
		pipelines:       PipelineRuntime.new(plan, listener_id, routes, assets_root, worker_root,
			primary_env, additional_workers)
		transformers:    TransformerRuntimeHub.from_plan(plan)
		protocol_update: protocol_runtime_plan_update_from_plan(plan, listener_id)
	}
}

fn (mut app App) apply_runtime_plan_runtime_projection(plan runtime_plan.RuntimePlan, projection RuntimePlanRuntimeProjection) {
	app.plan = plan
	app.pipelines = projection.pipelines
	app.transformers = projection.transformers
	app.protocols.apply_plan_update(projection.protocol_update)
}
