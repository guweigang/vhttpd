module main

import dispatch
import relay

fn test_relay_delivery_http_outcome_accepts_available_carrier_plan() {
	mut registry := relay.new_carrier_registry()
	registry.register('edge', 'carrier_edge') or { panic(err) }
	projection := relay.delivery_projection(registry, dispatch.relay_delivery_outcome('relay:edge',
		{
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))

	outcome := relay_delivery_http_outcome(projection)

	assert outcome.kind == .accepted_event
	assert outcome.status == 202
	assert outcome.metadata['relay_event'] == 'carrier.dispatch'
	assert outcome.metadata['relay_id'] == 'edge'
	assert outcome.metadata['carrier_id'] == 'carrier_edge'
	assert outcome.metadata['trace_id'] == 'trace_1'
	assert outcome.metadata['channel_id'] == 'chan_1'
}

fn test_relay_delivery_http_outcome_reports_unavailable_carrier() {
	projection := relay.delivery_projection(relay.new_carrier_registry(), dispatch.relay_delivery_outcome('relay:edge',
		{
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))

	outcome := relay_delivery_http_outcome(projection)

	assert outcome.kind == .failure
	assert outcome.status == 503
	assert outcome.error_class == 'relay_carrier_unavailable'
	assert outcome.error == 'relay_carrier_unavailable:edge'
	assert outcome.metadata['relay_event'] == 'carrier.dispatch_unavailable'
	assert outcome.metadata['carrier_id'] == 'disabled:edge'
}

fn test_relay_delivery_http_outcome_reports_projection_error() {
	projection := relay.delivery_projection(relay.new_carrier_registry(), dispatch.response_outcome(200,
		map[string]string{}, 'ok'))

	outcome := relay_delivery_http_outcome(projection)

	assert outcome.kind == .failure
	assert outcome.status == 500
	assert outcome.error_class == 'relay_delivery_projection'
	assert outcome.error == 'relay_delivery_invalid_outcome:response'
}
