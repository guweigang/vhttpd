module ws

import relay

fn test_receive_relay_websocket_payload_routes_text_payload_to_relay_runtime() {
	mut rt := relay.empty_runtime()
	raw := relay.encode_frame(relay.WireFrame{
		version:    relay.wire_version
		kind:       .open
		id:         'frm_open'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	}) or { panic(err) }

	outcome := receive_relay_websocket_payload(mut rt, 'carrier_edge', 'text', raw, 2)

	assert outcome.action == .forwarded
	assert outcome.frame_id == 'frm_open'
	assert rt.channels.channels['chan_1'].node_id == 'carrier_edge'
}

fn test_receive_relay_websocket_payload_rejects_non_text_payload() {
	mut rt := relay.empty_runtime()

	outcome := receive_relay_websocket_payload(mut rt, 'carrier_edge', 'binary', 'abc', 2)

	assert outcome.action == .rejected
	assert outcome.carrier_id == 'carrier_edge'
	assert outcome.error == 'relay_websocket_unsupported_opcode:binary'
	assert rt.channels.channels.len == 0
}
