module main

import runtime_plan

// One HTTP request retains immutable routing inputs and the published registry.
// Worker/executor references remain borrowed: their owners control admission and
// retirement, so a stopped generation rejects work instead of falling forward.
struct HttpDispatchView {
	plan         runtime_plan.RuntimePlan
	pipelines    PipelineRuntime
	transformers TransformerRuntimeHub
	engines      EngineRuntime
	scheme       string
}

fn (app &App) http_dispatch_view() HttpDispatchView {
	app.mu.@lock()
	defer { app.mu.unlock() }
	return HttpDispatchView{
		plan:         app.plan
		pipelines:    app.pipelines
		transformers: app.transformers
		engines:      EngineRuntime{ primary: app.engines.primary, additional: app.engines.additional.clone() }
		scheme:       app.lifecycle.data_plane_scheme
	}
}
