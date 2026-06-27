module main

import runtime_plan
import relay
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

fn test_relay_pipeline_runtime_projects_frame_to_pipeline_exchanges() {
	plan := runtime_plan.RuntimePlan{
		relays:    {
			'edge': runtime_plan.RelayPlan{
				id:      'edge'
				mode:    'agent'
				carrier: 'websocket'
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'edge/local'
				ingress: runtime_plan.ResourceRef{
					domain: .relay
					id:     'edge'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .terminal
					id:     'response'
				}
			},
		]
	}
	rt := PipelineRuntime.new(plan, 'default', []RuntimeRouteRule{}, '', '', map[string]string{},
		map[string]&worker.WorkerState{})
	exchanges := rt.relay.ingress_exchanges('edge', 'agent:edge', relay.WireFrame{
		version:    relay.wire_version
		kind:       .data
		id:         'frm-1'
		trace_id:   'trace-1'
		channel_id: 'chan-1'
		body:       'payload'
	}, 456)

	assert exchanges.len == 1
	assert exchanges[0].ingress == 'relay:edge'
	assert exchanges[0].pipeline == 'edge/local'
	assert exchanges[0].identity.id == 'frm-1'
	assert exchanges[0].created_at_ms == 456
	assert rt.relay.ingress_exchanges('missing', 'agent:edge', relay.WireFrame{}, 0).len == 0
}
