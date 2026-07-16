module relay

pub struct CarrierAttachResult {
pub:
	relay_id   string
	carrier_id string
	trace_id   string
	attached   bool
	error      string
}

pub fn (mut rt Runtime) attach_carrier(relay_id string, carrier_id string, trace_id string) CarrierAttachResult {
	rt.register_carrier(relay_id, carrier_id) or {
		return CarrierAttachResult{
			relay_id:   relay_id
			carrier_id: carrier_id
			trace_id:   trace_id
			error:      err.msg()
		}
	}
	return CarrierAttachResult{
		relay_id:   relay_id
		carrier_id: carrier_id
		trace_id:   trace_id
		attached:   true
	}
}

pub fn carrier_attach_event_fields(result CarrierAttachResult) map[string]string {
	return event_fields(if result.attached { 'carrier.attach' } else { 'carrier.attach_failed' },
		result.trace_id, {
		'relay_id':   result.relay_id
		'carrier_id': result.carrier_id
		'error':      result.error
	})
}

pub fn (mut rt Runtime) receive_from_carrier(carrier_id string, frame WireFrame, default_buffer_limit int) InboundOutcome {
	return rt.handle_inbound_frame(carrier_id, frame, default_buffer_limit)
}

pub fn (mut rt Runtime) receive_raw_from_carrier(carrier_id string, raw string, default_buffer_limit int) InboundOutcome {
	frame := decode_frame(raw) or {
		return InboundOutcome{
			action:     .rejected
			carrier_id: carrier_id
			error:      err.msg()
		}
	}
	return rt.receive_from_carrier(carrier_id, frame, default_buffer_limit)
}

pub fn (mut rt Runtime) detach_carrier(relay_id string, trace_id string) CarrierDetachResult {
	return rt.unregister_carrier(relay_id, trace_id)
}

pub fn send_to_carrier(mut carrier Carrier, outbound OutboundOutcome) CarrierSendResult {
	if outbound.action != .ready {
		return CarrierSendResult{
			ok:       false
			trace_id: outbound.trace_id
			frame_id: outbound.frame_id
			error:    if outbound.error != '' { outbound.error } else { 'relay_outbound_not_ready:${outbound.action}' }
		}
	}
	if !carrier.connected() {
		return CarrierSendResult{
			ok:       false
			trace_id: outbound.trace_id
			frame_id: outbound.frame_id
			error:    'relay_carrier_not_connected:${carrier.id()}'
		}
	}
	return carrier.send(outbound.frame)
}
