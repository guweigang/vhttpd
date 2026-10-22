module main

import runtime_plan

// Published plans and their containers are immutable after publication. Retain
// that value while the App lock protects the reference/JSON pair, then project
// outside the lock. This view owns no runtime/native handles.
struct AdminPlanView {
	generation u64
	plan       runtime_plan.RuntimePlan
	json       string
}

fn (app &App) admin_plan_view() AdminPlanView {
	app.mu.@lock()
	defer { app.mu.unlock() }
	return AdminPlanView{ generation: app.replacement.plan_generation, plan: app.plan, json: app.protocols.runtime_plan_json }
}

fn (app &App) admin_transformer_snapshot() TransformerRuntimeSnapshot {
	app.mu.@lock()
	defer { app.mu.unlock() }
	return app.transformers.snapshot()
}
