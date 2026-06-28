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

	outcome := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome_with_completion('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}, 'wait', 2500))

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

fn test_track_outbound_delivery_opens_local_channel() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }
	outbound := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
		'frame_kind': 'open'
		'route':      'relay/local-response'
	}))

	tracking := rt.track_outbound_delivery(outbound, 32)

	assert tracking.action == .opened
	assert tracking.trace_id == 'trace_1'
	assert tracking.frame_id == 'req_1'
	assert tracking.channel_id == 'chan_1'
	assert rt.channels.channels['chan_1'].node_id == 'local:edge'
	assert rt.channels.channels['chan_1'].route == 'relay/local-response'
	assert rt.channels.channels['chan_1'].buffer_limit == 32
}

fn test_track_outbound_delivery_rejects_unavailable_outbound() {
	mut rt := empty_runtime()
	outbound := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))

	tracking := rt.track_outbound_delivery(outbound, 32)

	assert tracking.action == .rejected
	assert tracking.trace_id == 'trace_1'
	assert tracking.frame_id == 'req_1'
	assert tracking.error == 'relay_carrier_unavailable:edge'
}

fn test_finish_outbound_delivery_retires_local_channel() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }
	outbound := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':       'trace_1'
		'request_id':     'req_1'
		'channel_id':     'chan_1'
		'correlation_id': 'corr_1'
		'frame_kind':     'open'
	}))
	rt.track_outbound_delivery(outbound, 32)

	finished := rt.finish_outbound_delivery(outbound)

	assert finished.action == .closed
	assert finished.channel_id == 'chan_1'
	assert rt.snapshot().channel_count == 0
	assert rt.channels.channel_for_correlation('corr_1') == none
}

fn test_finish_outbound_delivery_reports_missing_channel() {
	mut rt := empty_runtime()
	outbound := OutboundOutcome{
		action:   .ready
		trace_id: 'trace_1'
		frame_id: 'frm_1'
		frame:    WireFrame{
			version:    wire_version
			kind:       .open
			id:         'frm_1'
			trace_id:   'trace_1'
			channel_id: 'missing'
		}
	}

	finished := rt.finish_outbound_delivery(outbound)

	assert finished.action == .rejected
	assert finished.channel_id == 'missing'
	assert finished.error == 'relay_channel_unknown:missing'
}
