module main

import json
import runtime_plan

fn test_runtime_plan_with_projection_diagnostics_appends_to_runtime_visible_plan() {
	plan := runtime_plan.RuntimePlan{
		diagnostics: [
			runtime_plan.PlanDiagnostic{
				severity: 'info'
				code:     'compiled'
				path:     'source'
				message:  'compiled'
			},
		]
		listeners:   {
			'web': runtime_plan.ListenerPlan{
				id:       'web'
				protocol: 'http'
			}
		}
		adapters:    {
			'ws': runtime_plan.AdapterPlan{
				id:   'ws'
				kind: 'websocket'
			}
		}
		pipelines:   [
			runtime_plan.PipelinePlan{
				id:      'ws-on-http'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'ws'
				}
			},
		]
	}

	runtime_visible_plan := runtime_plan_with_projection_diagnostics(plan)
	assert runtime_visible_plan.diagnostics.len == 4
	assert runtime_visible_plan.diagnostics[0].code == 'compiled'
	assert runtime_visible_plan.diagnostics[1].code == 'pipeline_capability_mismatch'
	assert runtime_visible_plan.diagnostics[1].path == 'pipelines.ws-on-http'

	encoded := json.encode(runtime_visible_plan)
	assert encoded.contains('"diagnostics"')
	assert encoded.contains('"pipeline_capability_mismatch"')
	assert encoded.contains('"pipelines.ws-on-http"')
}

fn test_runtime_plan_with_projection_diagnostics_is_idempotent() {
	plan := runtime_plan.RuntimePlan{
		listeners: {
			'web': runtime_plan.ListenerPlan{
				id:       'web'
				protocol: 'http'
			}
		}
		adapters:  {
			'ws': runtime_plan.AdapterPlan{
				id:   'ws'
				kind: 'websocket'
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'ws-on-http'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'ws'
				}
			},
		]
	}

	once := runtime_plan_with_projection_diagnostics(plan)
	twice := runtime_plan_with_projection_diagnostics(once)

	assert once.diagnostics.len == 3
	assert twice.diagnostics.len == once.diagnostics.len
	assert twice.diagnostics.map(it.message) == once.diagnostics.map(it.message)
}
