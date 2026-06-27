module ws

import relay

pub fn receive_relay_websocket_payload(mut rt relay.Runtime, carrier_id string, opcode string, payload string, default_buffer_limit int) relay.InboundOutcome {
	if opcode != '' && opcode != 'text' {
		return relay.InboundOutcome{
			action:     .rejected
			carrier_id: carrier_id
			error:      'relay_websocket_unsupported_opcode:${opcode}'
		}
	}
	return rt.receive_raw_from_carrier(carrier_id, payload, default_buffer_limit)
}
