module main

import dispatch
import relay

fn test_relay_delivery_http_outcome_accepts_available_carrier_plan() {
	mut rt := relay.empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }
	projection := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))

	outcome := relay_delivery_http_outcome(projection)

	assert outcome.kind == .accepted_event
	assert outcome.status == 202
	assert outcome.metadata['relay_event'] == 'outbound.ready'
	assert outcome.metadata['relay_id'] == 'edge'
	assert outcome.metadata['carrier_id'] == 'carrier_edge'
	assert outcome.metadata['trace_id'] == 'trace_1'
	assert outcome.metadata['channel_id'] == 'chan_1'
}

fn test_relay_delivery_http_outcome_reports_unavailable_carrier() {
	rt := relay.empty_runtime()
	projection := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))

	outcome := relay_delivery_http_outcome(projection)

	assert outcome.kind == .failure
	assert outcome.status == 503
	assert outcome.error_class == 'relay_carrier_unavailable'
	assert outcome.error == 'relay_carrier_unavailable:edge'
	assert outcome.metadata['relay_event'] == 'outbound.unavailable'
	assert outcome.metadata['carrier_id'] == 'disabled:edge'
}

fn test_relay_delivery_http_outcome_reports_projection_error() {
	rt := relay.empty_runtime()
	projection :=
		rt.prepare_outbound_delivery(dispatch.response_outcome(200, map[string]string{}, 'ok'))

	outcome := relay_delivery_http_outcome(projection)

	assert outcome.kind == .failure
	assert outcome.status == 500
	assert outcome.error_class == 'relay_delivery_projection'
	assert outcome.error == 'relay_delivery_invalid_outcome:response'
}

fn test_relay_delivery_completion_policy_http_outcome_reports_unsupported_wait() {
	mut rt := relay.empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }
	projection := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':              'trace_1'
		'request_id':            'req_1'
		'channel_id':            'chan_1'
		'completion_mode':       'wait'
		'completion_timeout_ms': '1500'
	}))

	outcome := relay_delivery_completion_policy_http_outcome(projection)

	assert outcome.kind == .failure
	assert outcome.status == 501
	assert outcome.error_class == 'relay_completion_policy_unsupported'
	assert outcome.error == 'relay_completion_policy_unsupported:http:wait'
	assert outcome.metadata['completion_mode'] == 'wait'
	assert outcome.metadata['completion_timeout_ms'] == '1500'
	assert outcome.metadata['supported_completion_mode'] == 'accepted'
}

fn test_relay_delivery_send_http_outcome_accepts_successful_send() {
	mut rt := relay.empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }
	projection := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))

	outcome := relay_delivery_send_http_outcome(projection, relay.CarrierSendResult{
		ok:       true
		trace_id: 'trace_1'
		frame_id: 'req_1'
	})

	assert outcome.kind == .accepted_event
	assert outcome.status == 202
	assert outcome.metadata['relay_event'] == 'response_completion.sent'
	assert outcome.metadata['outbound_relay_event'] == 'outbound.ready'
	assert outcome.metadata['relay_id'] == 'edge'
	assert outcome.metadata['carrier_id'] == 'carrier_edge'
	assert outcome.metadata['carrier_relay_event'] == 'carrier.send'
	assert outcome.metadata['carrier_queued'] == 'false'
}

fn test_relay_delivery_send_http_outcome_reports_send_failure() {
	mut rt := relay.empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }
	projection := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))

	outcome := relay_delivery_send_http_outcome(projection, relay.CarrierSendResult{
		ok:       false
		trace_id: 'trace_1'
		frame_id: 'req_1'
		error:    'relay_carrier_not_connected:carrier_edge'
	})

	assert outcome.kind == .failure
	assert outcome.status == 503
	assert outcome.error_class == 'relay_response_completion_failed'
	assert outcome.error == 'relay_carrier_not_connected:carrier_edge'
	assert outcome.metadata['relay_event'] == 'response_completion.failed'
	assert outcome.metadata['outbound_relay_event'] == 'outbound.ready'
	assert outcome.metadata['carrier_relay_event'] == 'carrier.send_failed'
	assert outcome.metadata['carrier_error'] == 'relay_carrier_not_connected:carrier_edge'
}
