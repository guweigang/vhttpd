module main

import runtime_plan
import worker

fn test_pipeline_runtime_projects_relay_pipeline_descriptors() {
	plan := runtime_plan.RuntimePlan{
		relays:    {
			'edge': runtime_plan.RelayPlan{
				id:      'edge'
				mode:    'agent'
				carrier: 'websocket'
			}
		}
		adapters:  {
			'local': runtime_plan.AdapterPlan{
				id:   'local'
				kind: 'fixed-response'
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:         'edge/local'
				ingress:    runtime_plan.ResourceRef{
					domain: .relay
					id:     'edge'
				}
				transforms: [
					runtime_plan.ResourceRef{
						domain: .transform
						id:     'relay_route'
					},
				]
				egress:     runtime_plan.ResourceRef{
					domain: .adapter
					id:     'local'
				}
			},
		]
	}

	rt := PipelineRuntime.new(plan, 'default', []RuntimeRouteRule{}, '', '', map[string]string{},
		map[string]&worker.WorkerState{})
	descriptors := rt.relay.pipeline_descriptors('edge')

	assert descriptors.len == 1
	assert descriptors[0].id == 'edge/local'
	assert descriptors[0].ingress == 'relay:edge'
	assert descriptors[0].transforms == ['transform:relay_route']
	assert descriptors[0].egress == 'adapter:local'
	assert rt.relay.pipeline_descriptors('missing').len == 0
}
