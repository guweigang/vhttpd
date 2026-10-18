module main

// Transform definitions and engine lookup belong to one publication. These
// references borrow the executor owners; retirement still controls admission.
struct TransformDispatchView {
	transformers TransformerRuntimeHub
	engines      EngineRuntime
}

fn (app &App) transform_dispatch_view() TransformDispatchView {
	app.mu.@lock()
	defer { app.mu.unlock() }
	return TransformDispatchView{
		transformers: app.transformers
		engines:      EngineRuntime{ primary: app.engines.primary, additional: app.engines.additional.clone() }
	}
}

fn (view PipelineDispatchView) transform_dispatch_view() TransformDispatchView {
	return TransformDispatchView{ transformers: view.transformers, engines: view.engines }
}

fn (view HttpDispatchView) transform_dispatch_view() TransformDispatchView {
	return TransformDispatchView{ transformers: view.transformers, engines: view.engines }
}
