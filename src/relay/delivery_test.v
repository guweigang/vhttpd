module relay

import dispatch

fn test_relay_id_from_target_normalizes_relay_targets() {
	assert relay_id_from_target('relay:edge') == 'edge'
	assert relay_id_from_target('relay:edge:client') == 'edge'
	assert relay_id_from_target('edge') == 'edge'
	assert relay_id_from_target('') == ''
}

fn test_wire_frame_from_delivery_outcome_uses_metadata_identity() {
	outcome := dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':      'trace_1'
		'request_id':    'req_1'
		'channel_id':    'chan_1'
		'correlation_id': 'corr_1'
		'frame_id':      'frm_1'
		'frame_kind':    'open'
		'body':          'payload'
		'route':         'site/main'
	})

	frame := wire_frame_from_delivery_outcome(outcome)

	assert frame.kind == .open
	assert frame.id == 'frm_1'
	assert frame.request_id == 'req_1'
	assert frame.trace_id == 'trace_1'
	assert frame.channel_id == 'chan_1'
	assert frame.correlation_id == 'corr_1'
	assert frame.route == 'site/main'
	assert frame.body == 'payload'
}

fn test_delivery_projection_uses_registered_carrier_plan() {
	mut registry := new_carrier_registry()
	registry.register('edge', 'carrier_edge') or { panic(err) }
	outcome := dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	})

	projection := delivery_projection(registry, outcome)

	assert projection.error == ''
	assert projection.relay_id == 'edge'
	assert projection.frame.trace_id == 'trace_1'
	assert projection.plan.available
	assert projection.plan.carrier_id == 'carrier_edge'
}

fn test_delivery_projection_reports_unavailable_carrier_plan() {
	registry := new_carrier_registry()
	outcome := dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	})

	projection := delivery_projection(registry, outcome)

	assert projection.error == ''
	assert projection.relay_id == 'edge'
	assert !projection.plan.available
	assert projection.plan.carrier_id == 'disabled:edge'
	assert projection.plan.error == 'relay_carrier_unavailable:edge'
}

fn test_delivery_projection_rejects_non_relay_outcome() {
	projection := delivery_projection(new_carrier_registry(), dispatch.response_outcome(200,
		map[string]string{}, 'ok'))

	assert projection.error == 'relay_delivery_invalid_outcome:response'
}
