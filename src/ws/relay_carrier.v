module ws

import relay

// Bind once before business callbacks. The returned target cannot reacquire a
// later registration merely because its public connection ID is the same.
pub struct RelayCarrierContext {
pub:
	bind_fn fn (string) RelayCarrierTarget @[required]
}

pub struct RelayCarrierTarget {
pub:
	conn_open_fn    fn () bool               @[required]
	send_to_fn      fn (string, string) bool @[required]
	close_target_fn fn (int, string)         @[required]
}

pub struct RelayCarrier {
	target RelayCarrierTarget @[required]
pub:
	conn_id string
}

pub fn new_relay_carrier(rt RelayCarrierContext, conn_id string) RelayCarrier {
	return RelayCarrier{ target: rt.bind_fn(conn_id), conn_id: conn_id }
}

// Capture under the hub mutex. Absence is also captured, so an unregistered
// carrier cannot append to a future-open queue or adopt a later connection.
pub fn hub_relay_carrier_target(mut hub HubState, conn_id string) RelayCarrierTarget {
	hub.mu.@lock()
	expected := if current := hub.conns[conn_id] {
		?&DispatchConnState(current.lifecycle)
	} else {
		?&DispatchConnState(none)
	}
	hub.mu.unlock()
	return RelayCarrierTarget{
		conn_open_fn:    fn [mut hub, conn_id, expected] () bool {
			lifecycle := expected or { return false }
			hub.mu.@lock()
			defer { hub.mu.unlock() }
			current := hub.conns[conn_id] or { return false }
			return voidptr(current.lifecycle) == voidptr(lifecycle) && lifecycle.can_queue()
		}
		send_to_fn:      fn [mut hub, conn_id, expected] (data string, opcode string) bool {
			lifecycle := expected or { return false }
			return hub_send_owned_to(mut hub, conn_id, lifecycle, data, opcode)
		}
		close_target_fn: fn [mut hub, conn_id, expected] (code int, reason string) {
			lifecycle := expected or { return }
			hub_close_owned_target(mut hub, conn_id, lifecycle, code, reason)
		}
	}
}

pub fn (carrier RelayCarrier) id() string {
	return carrier.conn_id
}

pub fn (carrier RelayCarrier) connected() bool {
	return carrier.target.conn_open_fn()
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
	if carrier.target.send_to_fn(raw, 'text') {
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
	carrier.target.close_target_fn(1000, 'relay carrier closed')
}
