module main

import upstream.transport

fn test_stream_dispatch_open_delivery_outcome_projects_sse_response() {
	outcome := stream_dispatch_open_delivery_outcome(transport.StreamDispatchResponse{
		id:          'disp-1'
		stream_type: 'sse'
		headers:     {
			'x-dispatch': 'yes'
		}
		state:       {
			'cursor': '1'
		}
	})

	assert outcome.kind == .stream_plan
	assert outcome.target == 'stream-dispatch:disp-1'
	assert outcome.headers['content-type'] == 'text/event-stream'
	assert outcome.headers['x-dispatch'] == 'yes'
	assert outcome.metadata['stream_strategy'] == 'dispatch'
	assert outcome.metadata['stream_type'] == 'sse'
	assert outcome.metadata['cursor'] == '1'
}

fn test_stream_dispatch_open_delivery_outcome_projects_text_response() {
	outcome := stream_dispatch_open_delivery_outcome(transport.StreamDispatchResponse{
		stream_type:  'text'
		content_type: 'application/x-ndjson'
	})

	assert outcome.kind == .stream_plan
	assert outcome.target == 'stream-dispatch:open'
	assert outcome.headers['content-type'] == 'application/x-ndjson'
	assert outcome.metadata['stream_type'] == 'text'
}
