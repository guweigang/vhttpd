module main

import dispatch
import relay
import runtime_plan
import worker

fn test_dispatch_relay_ingress_frame_runs_terminal_response_pipeline() {
	mut app := App{
		plan: runtime_plan.RuntimePlan{
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
	}
	app.pipelines = PipelineRuntime.new(app.plan, 'default', []RuntimeRouteRule{}, '', '',
		map[string]string{}, map[string]&worker.WorkerState{})

	outcomes := app.dispatch_relay_ingress_frame('edge', 'agent:edge', relay.WireFrame{
		version:    relay.wire_version
		kind:       .data
		id:         'frm-1'
		trace_id:   'trace-1'
		channel_id: 'chan-1'
		body:       'payload'
	}, 123)

	assert outcomes.len == 1
	assert outcomes[0].pipeline_id == 'edge/local'
	assert outcomes[0].exchange_id == 'frm-1'
	assert outcomes[0].trace_id == 'trace-1'
	assert outcomes[0].action == 'response'
	assert outcomes[0].status == 200
}

fn test_dispatch_relay_ingress_frame_reports_missing_pipeline() {
	mut app := App{
		plan: runtime_plan.RuntimePlan{}
	}
	app.pipelines = PipelineRuntime.new(app.plan, 'default', []RuntimeRouteRule{}, '', '',
		map[string]string{}, map[string]&worker.WorkerState{})

	outcomes := app.dispatch_relay_ingress_frame('missing', 'agent:edge', relay.WireFrame{
		id:       'frm-1'
		trace_id: 'trace-1'
	}, 0)

	assert outcomes.len == 1
	assert outcomes[0].action == 'rejected'
	assert outcomes[0].status == 404
	assert outcomes[0].error_class == 'relay_pipeline_not_found'
}

fn test_dispatch_relay_pipeline_exchange_reports_unsupported_egress() {
	mut app := App{
		plan: runtime_plan.RuntimePlan{
			pipelines: [
				runtime_plan.PipelinePlan{
					id:      'edge/local'
					ingress: runtime_plan.ResourceRef{
						domain: .relay
						id:     'edge'
					}
					egress:  runtime_plan.ResourceRef{
						domain: .adapter
						id:     'local'
					}
				},
			]
		}
	}
	mut exchange := dispatch.relay_ingress_exchange(dispatch.RelayIngressRequest{
		relay_id:   'edge'
		frame_id:   'frm-1'
		trace_id:   'trace-1'
		request_id: 'req-1'
		pipeline:   'edge/local'
		session_id: 'sess-1'
		body:       'payload'
	})

	outcome := app.dispatch_relay_pipeline_exchange(mut exchange)

	assert outcome.action == 'failed'
	assert outcome.status == 501
	assert outcome.error == 'relay_pipeline_egress_unsupported:adapter:local'
	assert outcome.error_class == 'relay_pipeline_egress_unsupported'
}
