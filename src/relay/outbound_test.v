module relay

import dispatch

fn test_prepare_outbound_delivery_reports_ready_carrier() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }

	outcome := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))

	assert outcome.action == .ready
	assert outcome.relay_id == 'edge'
	assert outcome.carrier_id == 'carrier_edge'
	assert outcome.trace_id == 'trace_1'
	assert outcome.frame_id == 'req_1'
	assert outcome.frame.channel_id == 'chan_1'
	assert outcome.completion.mode == 'accepted'
	assert outcome.fields['relay_event'] == 'outbound.ready'
	assert outcome.fields['carrier_id'] == 'carrier_edge'
	assert outcome.fields['channel_id'] == 'chan_1'
	assert outcome.fields['completion_mode'] == 'accepted'
}

fn test_prepare_outbound_delivery_includes_completion_policy_fields() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }

	outcome := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':              'trace_1'
		'request_id':            'req_1'
		'channel_id':            'chan_1'
		'completion_mode':       'wait'
		'completion_timeout_ms': '2500'
	}))

	assert outcome.action == .ready
	assert outcome.completion.mode == 'wait'
	assert outcome.completion.timeout_ms == 2500
	assert outcome.fields['completion_mode'] == 'wait'
	assert outcome.fields['completion_timeout_ms'] == '2500'
}

fn test_prepare_outbound_delivery_reports_unavailable_carrier() {
	rt := empty_runtime()

	outcome := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))

	assert outcome.action == .unavailable
	assert outcome.carrier_id == 'disabled:edge'
	assert outcome.error == 'relay_carrier_unavailable:edge'
	assert outcome.fields['relay_event'] == 'outbound.unavailable'
	assert outcome.fields['error'] == 'relay_carrier_unavailable:edge'
}

fn test_prepare_outbound_delivery_rejects_invalid_outcome() {
	rt := empty_runtime()

	outcome :=
		rt.prepare_outbound_delivery(dispatch.response_outcome(200, map[string]string{}, 'ok'))

	assert outcome.action == .rejected
	assert outcome.error == 'relay_delivery_invalid_outcome:response'
	assert outcome.fields['relay_event'] == 'outbound.rejected'
	assert outcome.fields['error'] == 'relay_delivery_invalid_outcome:response'
}
