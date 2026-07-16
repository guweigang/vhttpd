module main

import upstream.transport

fn test_upstream_plan_delivery_outcome_projects_sse_stream_plan() {
	outcome := upstream_plan_delivery_outcome(transport.WorkerUpstreamPlanFrame{
		name:               'chat'
		transport:          'http'
		output_stream_type: 'sse'
		response_headers:   {
			'x-provider': 'mock'
		}
		meta:               {
			'field_path': 'message.content'
		}
	})

	assert outcome.kind == .stream_plan
	assert outcome.target == 'upstream:chat'
	assert outcome.headers['content-type'] == 'text/event-stream'
	assert outcome.headers['x-provider'] == 'mock'
	assert outcome.metadata['stream_strategy'] == 'upstream_plan'
	assert outcome.metadata['stream_type'] == 'sse'
	assert outcome.metadata['upstream_name'] == 'chat'
	assert outcome.metadata['upstream_transport'] == 'http'
	assert outcome.metadata['field_path'] == 'message.content'
}

fn test_upstream_plan_delivery_outcome_projects_text_stream_plan() {
	outcome := upstream_plan_delivery_outcome(transport.WorkerUpstreamPlanFrame{
		id:                  'plan-1'
		output_stream_type:  'text'
		output_content_type: 'application/x-ndjson'
	})

	assert outcome.kind == .stream_plan
	assert outcome.target == 'upstream:plan-1'
	assert outcome.headers['content-type'] == 'application/x-ndjson'
	assert outcome.metadata['stream_type'] == 'text'
}
