module main

import dispatch
import upstream.transport

fn worker_stream_start_delivery_outcome(start transport.WorkerStreamFrame, fallback_stream_type string) dispatch.DeliveryOutcome {
	status := if start.status > 0 { start.status } else { 200 }
	stream_type := if start.stream_type != '' { start.stream_type } else { fallback_stream_type }
	content_type := if start.content_type != '' {
		start.content_type
	} else if stream_type == 'sse' {
		'text/event-stream'
	} else {
		'text/plain; charset=utf-8'
	}
	mut headers := start.headers.clone()
	headers['content-type'] = content_type
	return dispatch.stream_plan_outcome_with_status(status, worker_stream_target(start), headers,
		{
		'stream_strategy': 'direct'
		'stream_type':     stream_type
	})
}

fn worker_stream_target(start transport.WorkerStreamFrame) string {
	if start.id != '' {
		return 'worker-stream:${start.id}'
	}
	return 'worker-stream:direct'
}
