module main

import relay
import runtime_plan

struct RelayRuntimeBuildResult {
	runtime     relay.Runtime
	diagnostics []runtime_plan.PlanDiagnostic
}

fn relay_runtime_with_diagnostics_from_plan(plan runtime_plan.RuntimePlan) RelayRuntimeBuildResult {
	runtime := relay.new_runtime(plan) or {
		return RelayRuntimeBuildResult{
			runtime:     relay.empty_runtime()
			diagnostics: [
				runtime_plan.PlanDiagnostic{
					severity: 'error'
					code:     'relay_runtime_failed'
					path:     'relays'
					message:  'failed to build relay runtime: ${err.msg()}'
				},
			]
		}
	}
	return RelayRuntimeBuildResult{
		runtime: runtime
	}
}
