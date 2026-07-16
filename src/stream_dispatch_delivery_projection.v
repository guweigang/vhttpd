module main

import dispatch
import upstream.transport

fn stream_dispatch_open_delivery_outcome(open_resp transport.StreamDispatchResponse) dispatch.DeliveryOutcome {
	stream_type := if open_resp.stream_type == 'text' { 'text' } else { 'sse' }
	content_type := if open_resp.content_type != '' {
		open_resp.content_type
	} else if stream_type == 'sse' {
		'text/event-stream'
	} else {
		'text/plain; charset=utf-8'
	}
	mut headers := open_resp.headers.clone()
	headers['content-type'] = content_type
	mut metadata := open_resp.state.clone()
	metadata['stream_strategy'] = 'dispatch'
	metadata['stream_type'] = stream_type
	return dispatch.stream_plan_outcome(stream_dispatch_target(open_resp), headers, metadata)
}

fn stream_dispatch_target(open_resp transport.StreamDispatchResponse) string {
	if open_resp.id != '' {
		return 'stream-dispatch:${open_resp.id}'
	}
	return 'stream-dispatch:open'
}
