module ws

import relay

pub struct RelayCarrier {
pub:
	conn_id string
pub mut:
	rt RuntimeContext
}

pub fn new_relay_carrier(rt RuntimeContext, conn_id string) RelayCarrier {
	return RelayCarrier{
		rt:      rt
		conn_id: conn_id
	}
}

pub fn (carrier RelayCarrier) id() string {
	return carrier.conn_id
}

pub fn (carrier RelayCarrier) connected() bool {
	return carrier.rt.conn_open(carrier.conn_id)
}

pub fn (mut carrier RelayCarrier) send(frame relay.WireFrame) relay.CarrierSendResult {
	raw := relay.encode_frame(frame) or {
		return relay.CarrierSendResult{
			ok:       false
			trace_id: frame.trace_id
			frame_id: frame.id
			error:    err.msg()
		}
	}
	if carrier.rt.send_to(carrier.conn_id, raw, 'text') {
		return relay.CarrierSendResult{
			ok:       true
			trace_id: frame.trace_id
			frame_id: frame.id
		}
	}
	return relay.CarrierSendResult{
		ok:       false
		trace_id: frame.trace_id
		frame_id: frame.id
		error:    'relay_websocket_send_failed:${carrier.conn_id}'
	}
}

pub fn (mut carrier RelayCarrier) close_channel(channel_id string, trace_id string) relay.CarrierCloseResult {
	result := carrier.send(relay.WireFrame{
		version:    relay.wire_version
		kind:       .cancel
		id:         'close:${channel_id}'
		trace_id:   trace_id
		channel_id: channel_id
	})
	return relay.CarrierCloseResult{
		ok:         result.ok
		trace_id:   trace_id
		channel_id: channel_id
		error:      result.error
	}
}

pub fn (mut carrier RelayCarrier) close() {
	carrier.rt.close_target(carrier.conn_id, 1000, 'relay carrier closed')
}
