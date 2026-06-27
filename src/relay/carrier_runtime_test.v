module relay

import dispatch

struct TestCarrier {
	id_value  string
	connected_value bool
}

fn (carrier TestCarrier) id() string {
	return carrier.id_value
}

fn (carrier TestCarrier) connected() bool {
	return carrier.connected_value
}

fn (mut carrier TestCarrier) send(frame WireFrame) CarrierSendResult {
	return CarrierSendResult{
		ok:       true
		trace_id: frame.trace_id
		frame_id: frame.id
	}
}

fn (mut carrier TestCarrier) close_channel(channel_id string, trace_id string) CarrierCloseResult {
	return CarrierCloseResult{
		ok:         true
		trace_id:   trace_id
		channel_id: channel_id
	}
}

fn (mut carrier TestCarrier) close() {}

fn test_attach_and_detach_carrier_runtime() {
	mut rt := empty_runtime()

	attached := rt.attach_carrier('edge', 'carrier_edge', 'trace_1')
	detached := rt.detach_carrier('edge', 'trace_2')

	assert attached.attached
	assert attached.relay_id == 'edge'
	assert rt.carriers.registered('edge') == false
	assert detached.removed
	assert detached.carrier_id == 'carrier_edge'
	assert carrier_attach_event_fields(attached)['relay_event'] == 'carrier.attach'
}

fn test_receive_from_carrier_routes_to_inbound_runtime() {
	mut rt := empty_runtime()
	outcome := rt.receive_from_carrier('carrier_edge', WireFrame{
		version:    wire_version
		kind:       .open
		id:         'frm_open'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	}, 2)

	assert outcome.action == .forwarded
	assert outcome.forwarding.action == .opened
	assert rt.channels.channels['chan_1'].node_id == 'carrier_edge'
}

fn test_send_to_connected_carrier_sends_ready_outbound_frame() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }
	outbound := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))
	mut carrier := Carrier(TestCarrier{
		id_value:        'carrier_edge'
		connected_value: true
	})

	result := send_to_carrier(mut carrier, outbound)

	assert result.ok
	assert result.trace_id == 'trace_1'
	assert result.frame_id == 'req_1'
}

fn test_send_to_carrier_rejects_unavailable_outbound() {
	rt := empty_runtime()
	outbound := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))
	mut carrier := Carrier(TestCarrier{
		id_value:        'carrier_edge'
		connected_value: true
	})

	result := send_to_carrier(mut carrier, outbound)

	assert !result.ok
	assert result.error == 'relay_carrier_unavailable:edge'
}

fn test_send_to_carrier_rejects_disconnected_carrier() {
	mut rt := empty_runtime()
	rt.register_carrier('edge', 'carrier_edge') or { panic(err) }
	outbound := rt.prepare_outbound_delivery(dispatch.relay_delivery_outcome('relay:edge', {
		'trace_id':   'trace_1'
		'request_id': 'req_1'
		'channel_id': 'chan_1'
	}))
	mut carrier := Carrier(TestCarrier{
		id_value:        'carrier_edge'
		connected_value: false
	})

	result := send_to_carrier(mut carrier, outbound)

	assert !result.ok
	assert result.error == 'relay_carrier_not_connected:carrier_edge'
}
