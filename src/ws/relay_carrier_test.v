module ws

import relay

@[heap]
struct RelayCarrierProbe {
mut:
	open        bool
	sent_conn   string
	sent_opcode string
	sent_data   string
	sent        bool
	closed_conn string
	close_code  int
}

fn test_relay_carrier_reports_connection_state_from_runtime() {
	mut probe := &RelayCarrierProbe{
		open: true
	}
	rt := RuntimeContext{
		conn_open_fn: fn [mut probe] (_ string) bool {
			return probe.open
		}
	}
	carrier := new_relay_carrier(rt, 'conn_1')

	assert carrier.id() == 'conn_1'
	assert carrier.connected()
	probe.open = false
	assert !carrier.connected()
}

fn test_relay_carrier_sends_encoded_wire_frame_to_websocket_context() {
	mut probe := &RelayCarrierProbe{
		open: true
	}
	rt := RuntimeContext{
		conn_open_fn: fn (_ string) bool {
			return true
		}
		send_to_fn:   fn [mut probe] (conn_id string, data string, opcode string) bool {
			probe.sent_conn = conn_id
			probe.sent_opcode = opcode
			probe.sent_data = data
			return true
		}
	}
	mut carrier := new_relay_carrier(rt, 'conn_1')

	result := carrier.send(relay.WireFrame{
		version:    relay.wire_version
		kind:       .data
		id:         'frm_1'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
		body:       'hello'
	})
	decoded := relay.decode_frame(probe.sent_data) or { panic(err) }

	assert result.ok
	assert result.trace_id == 'trace_1'
	assert result.frame_id == 'frm_1'
	assert probe.sent_conn == 'conn_1'
	assert probe.sent_opcode == 'text'
	assert decoded.id == 'frm_1'
	assert decoded.body == 'hello'
}

fn test_relay_carrier_rejects_invalid_wire_frame_before_send() {
	mut probe := &RelayCarrierProbe{
		open: true
	}
	rt := RuntimeContext{
		conn_open_fn: fn (_ string) bool {
			return true
		}
		send_to_fn:   fn [mut probe] (_ string, _ string, _ string) bool {
			probe.sent = true
			return true
		}
	}
	mut carrier := new_relay_carrier(rt, 'conn_1')

	result := carrier.send(relay.WireFrame{
		version:  relay.wire_version
		kind:     .data
		id:       'frm_1'
		trace_id: 'trace_1'
	})

	assert !result.ok
	assert !probe.sent
	assert result.error == 'relay_wire_missing_channel_id'
}

fn test_relay_carrier_close_channel_sends_cancel_frame() {
	mut probe := &RelayCarrierProbe{
		open: true
	}
	rt := RuntimeContext{
		conn_open_fn: fn (_ string) bool {
			return true
		}
		send_to_fn:   fn [mut probe] (_ string, data string, _ string) bool {
			probe.sent_data = data
			return true
		}
	}
	mut carrier := new_relay_carrier(rt, 'conn_1')

	result := carrier.close_channel('chan_1', 'trace_1')
	decoded := relay.decode_frame(probe.sent_data) or { panic(err) }

	assert result.ok
	assert decoded.kind == .cancel
	assert decoded.channel_id == 'chan_1'
	assert decoded.trace_id == 'trace_1'
}

fn test_relay_carrier_close_closes_websocket_target() {
	mut probe := &RelayCarrierProbe{
		open: true
	}
	rt := RuntimeContext{
		conn_open_fn:    fn (_ string) bool {
			return true
		}
		close_target_fn: fn [mut probe] (conn_id string, code int, _ string) {
			probe.closed_conn = conn_id
			probe.close_code = code
		}
	}
	mut carrier := new_relay_carrier(rt, 'conn_1')

	carrier.close()

	assert probe.closed_conn == 'conn_1'
	assert probe.close_code == 1000
}
