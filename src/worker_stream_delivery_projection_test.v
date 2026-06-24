module main

import upstream.transport

fn test_worker_stream_start_delivery_outcome_projects_sse_start() {
	outcome := worker_stream_start_delivery_outcome(transport.WorkerStreamFrame{
		id:          'stream-1'
		status:      201
		stream_type: 'sse'
		headers:     {
			'x-worker': 'yes'
		}
	}, 'sse')

	assert outcome.kind == .stream_plan
	assert outcome.status == 201
	assert outcome.target == 'worker-stream:stream-1'
	assert outcome.headers['content-type'] == 'text/event-stream'
	assert outcome.headers['x-worker'] == 'yes'
	assert outcome.metadata['stream_strategy'] == 'direct'
	assert outcome.metadata['stream_type'] == 'sse'
}

fn test_worker_stream_start_delivery_outcome_projects_passthrough_start() {
	outcome := worker_stream_start_delivery_outcome(transport.WorkerStreamFrame{
		content_type: 'application/octet-stream'
	}, 'passthrough')

	assert outcome.kind == .stream_plan
	assert outcome.status == 200
	assert outcome.target == 'worker-stream:direct'
	assert outcome.headers['content-type'] == 'application/octet-stream'
	assert outcome.metadata['stream_type'] == 'passthrough'
}
