module main

import runtime_plan

// These published containers are immutable. Capture their references together;
// request processing and user callbacks run after releasing the publication lock.
// This view borrows engine owners and never owns their native handles.
struct PipelineDispatchView {
	plan         runtime_plan.RuntimePlan
	relay        RelayPipelineRuntime
	transformers TransformerRuntimeHub
	engines      EngineRuntime
}

fn (app &App) pipeline_dispatch_view() PipelineDispatchView {
	app.mu.@lock()
	defer { app.mu.unlock() }
	return PipelineDispatchView{
		plan:         app.plan
		relay:        app.pipelines.relay
		transformers: app.transformers
		engines:      EngineRuntime{ primary: app.engines.primary, additional: app.engines.additional.clone() }
	}
}
