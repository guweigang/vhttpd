module dispatch

fn test_stream_plan_outcome_carries_protocol_neutral_target() {
	mut headers := {
		'accept': 'text/event-stream'
	}
	mut metadata := {
		'mode': 'sse'
	}
	outcome := stream_plan_outcome('stream:worker', headers, metadata)
	headers['accept'] = 'changed'
	metadata['mode'] = 'changed'

	assert outcome.kind == .stream_plan
	assert outcome.status == 0
	assert outcome.target == 'stream:worker'
	assert outcome.headers['accept'] == 'text/event-stream'
	assert outcome.metadata['mode'] == 'sse'
}

fn test_session_plan_outcome_carries_protocol_neutral_target() {
	outcome := session_plan_outcome('websocket:chat', {
		'sec-websocket-protocol': 'chat'
	}, {
		'trace_id': 'trace-1'
	})

	assert outcome.kind == .session_plan
	assert outcome.status == 0
	assert outcome.target == 'websocket:chat'
	assert outcome.headers['sec-websocket-protocol'] == 'chat'
	assert outcome.metadata['trace_id'] == 'trace-1'
}

fn test_relay_delivery_outcome_carries_target_and_metadata() {
	outcome := relay_delivery_outcome('relay:feishu', {
		'carrier': 'websocket'
	})

	assert outcome.kind == .relay_delivery
	assert outcome.status == 0
	assert outcome.target == 'relay:feishu'
	assert outcome.metadata['carrier'] == 'websocket'
}
