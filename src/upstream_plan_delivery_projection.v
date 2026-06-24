module main

import dispatch
import upstream.transport

fn upstream_plan_delivery_outcome(plan transport.WorkerUpstreamPlanFrame) dispatch.DeliveryOutcome {
	stream_type := if plan.output_stream_type == 'text' { 'text' } else { 'sse' }
	content_type := if plan.output_content_type != '' {
		plan.output_content_type
	} else if stream_type == 'sse' {
		'text/event-stream'
	} else {
		'text/plain; charset=utf-8'
	}
	mut headers := plan.response_headers.clone()
	headers['content-type'] = content_type
	mut metadata := plan.meta.clone()
	metadata['stream_strategy'] = 'upstream_plan'
	metadata['stream_type'] = stream_type
	if plan.name != '' {
		metadata['upstream_name'] = plan.name
	}
	if plan.transport != '' {
		metadata['upstream_transport'] = plan.transport
	}
	return dispatch.stream_plan_outcome(upstream_plan_target(plan), headers, metadata)
}

fn upstream_plan_target(plan transport.WorkerUpstreamPlanFrame) string {
	if plan.name != '' {
		return 'upstream:${plan.name}'
	}
	if plan.id != '' {
		return 'upstream:${plan.id}'
	}
	return 'upstream:anonymous'
}
