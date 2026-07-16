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

fn test_relay_delivery_http_outcome_reports_wait_target_unavailable_without_tracking() {
	mut services := dispatch.RuntimeServices(dispatch.NoOpRuntimeServices{
		trace: 'trace_public'
	})
	public_exchange := dispatch.Exchange{
		identity: dispatch.ExchangeIdentity{
			id:         'frm_public'
			request_id: 'req_public'
			trace_id:   'trace_public'
		}
		kind:     .request
		ingress:  'listener:web'
		pipeline: 'public/relay'
		headers:  map[string]string{}
		metadata: map[string]string{}
		payload:  dispatch.RequestPayload{
			method: 'GET'
			path:   '/relay'
		}
	}
	mut adapter := dispatch.EgressAdapter(dispatch.relay_delivery_adapter('relay-edge',
		'relay:edge', 'wait', 1000, {
		'frame_kind': 'open'
		'route':      'relay/local-response'
	}))
	delivery := adapter.deliver(mut services, public_exchange) or { panic(err) }
	rt := relay.empty_runtime()
	outbound := rt.prepare_outbound_delivery(delivery)

	outcome := relay_delivery_http_outcome(outbound)

	assert outbound.action == .unavailable
	assert outcome.kind == .failure
	assert outcome.status == 503
	assert outcome.error_class == 'relay_carrier_unavailable'
	assert outcome.error == 'relay_carrier_unavailable:edge'
	assert outcome.metadata['relay_event'] == 'outbound.unavailable'
	assert outcome.metadata['trace_id'] == 'trace_public'
	assert outcome.metadata['channel_id'] == 'req_public'
	assert outcome.metadata['frame_id'] == 'frm_public'
	assert outcome.metadata['completion_mode'] == 'wait'
	assert outcome.metadata['completion_timeout_ms'] == '1000'
	assert outcome.metadata['carrier_id'] == 'disabled:edge'
	assert rt.snapshot().channel_count == 0
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

fn test_relay_delivery_completion_policy_http_outcome_reports_unsupported_stream() {
	mut rt := relay.empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }
	projection := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':              'trace_1'
		'request_id':            'req_1'
		'channel_id':            'chan_1'
		'completion_mode':       'stream'
		'completion_timeout_ms': '1500'
	}))

	outcome := relay_delivery_completion_policy_http_outcome(projection)

	assert outcome.kind == .failure
	assert outcome.status == 501
	assert outcome.error_class == 'relay_completion_policy_unsupported'
	assert outcome.error == 'relay_completion_policy_unsupported:http:stream'
	assert outcome.metadata['completion_mode'] == 'stream'
	assert outcome.metadata['completion_timeout_ms'] == '1500'
	assert outcome.metadata['supported_completion_mode'] == 'accepted,wait'
}

fn test_relay_delivery_send_http_outcome_accepts_successful_send() {
	mut rt := relay.empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }
	projection := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))

	outcome := relay_delivery_send_http_outcome(mut rt, projection, relay.CarrierSendResult{
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

fn test_relay_delivery_http_tracking_policy_only_tracks_wait() {
	assert !relay_delivery_http_needs_outbound_tracking('accepted')
	assert relay_delivery_http_needs_outbound_tracking('wait')
}

fn test_relay_delivery_send_http_outcome_reports_send_failure() {
	mut rt := relay.empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }
	projection := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))

	outcome := relay_delivery_send_http_outcome(mut rt, projection, relay.CarrierSendResult{
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

fn test_relay_delivery_send_http_outcome_can_complete_wait_from_returned_frame() {
	mut rt := relay.empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }
	rt.handle_frame(relay.WireFrame{
		version:    relay.wire_version
		kind:       .open
		id:         'frm_open'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	}, 'node_1', 4)
	rt.handle_frame(relay.WireFrame{
		version:       relay.wire_version
		kind:          .data
		id:            'relay-response:req_1'
		trace_id:      'trace_1'
		channel_id:    'chan_1'
		exchange_kind: 'response'
		metadata:      {
			'status': '209'
		}
		body:          'done'
	}, 'node_1', 4)
	projection := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome_with_completion('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}, 'wait', 1000))

	outcome := relay_delivery_send_http_outcome(mut rt, projection, relay.CarrierSendResult{
		ok:       true
		trace_id: 'trace_1'
		frame_id: 'req_1'
	})

	assert outcome.kind == .response
	assert outcome.status == 209
	assert outcome.body == 'done'
	assert outcome.metadata['relay_event'] == 'response_completion.completed'
	assert outcome.metadata['target_id'] == 'req_1'
	assert rt.snapshot().channel_count == 0
}

fn test_relay_delivery_send_http_outcome_times_out_wait_without_returned_frame() {
	mut rt := relay.empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }
	projection := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome_with_completion('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}, 'wait', 1))
	rt.track_outbound_delivery(projection, 4)

	outcome := relay_delivery_send_http_outcome(mut rt, projection, relay.CarrierSendResult{
		ok:       true
		trace_id: 'trace_1'
		frame_id: 'req_1'
	})

	assert outcome.kind == .failure
	assert outcome.status == 504
	assert outcome.error_class == 'relay_response_missing'
	assert outcome.error == 'relay_returned_frame_not_found:chan_1:req_1'
	assert outcome.metadata['relay_event'] == 'response_completion.missing'
	assert outcome.metadata['completion_mode'] == 'wait'
	assert outcome.metadata['completion_timeout_ms'] == '1'
	assert rt.snapshot().channel_count == 0
}
