module ws

import relay

pub fn receive_relay_websocket_payload(mut rt relay.Runtime, carrier_id string, opcode string, payload string, default_buffer_limit int) relay.InboundOutcome {
	return receive_relay_websocket_payload_for(mut rt, carrier_id, opcode, payload, default_buffer_limit, '')
}

// Validate the hub path before hello can publish a carrier mapping.
pub fn receive_relay_websocket_payload_for(mut rt relay.Runtime, carrier_id string, opcode string, payload string, default_buffer_limit int, expected_relay_id string) relay.InboundOutcome {
	if opcode != '' && opcode != 'text' {
		return relay.InboundOutcome{
			action:     .rejected
			carrier_id: carrier_id
			error:      'relay_websocket_unsupported_opcode:${opcode}'
		}
	}
	frame := relay.decode_frame(payload) or { return relay.InboundOutcome{ action: .rejected, carrier_id: carrier_id, error: err.msg() } }
	relay_id := frame.metadata['relay_id'] or { '' }
	if frame.kind == .hello && expected_relay_id != '' && relay_id != '' && relay_id != expected_relay_id {
		return relay.InboundOutcome{ action: .rejected, relay_id: relay_id, carrier_id: carrier_id, trace_id: frame.trace_id, frame_id: frame.id, frame: frame, error: 'relay_websocket_relay_mismatch:${relay_id}:${expected_relay_id}' }
	}
	return rt.receive_from_carrier(carrier_id, frame, default_buffer_limit)
}
