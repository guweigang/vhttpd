module relay

pub struct CarrierAttachResult {
pub:
	relay_id   string
	carrier_id string
	trace_id   string
	attached   bool
	binding    ?&CarrierBinding
	error      string
}

pub fn (mut rt Runtime) attach_carrier(relay_id string, carrier_id string, trace_id string) CarrierAttachResult {
	binding := rt.carriers.bind(relay_id, carrier_id) or {
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
		binding:    binding
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
			error:    if outbound.error != '' {
				outbound.error
			} else {
				'relay_outbound_not_ready:${outbound.action}'
			}
		}
	}
	if !outbound.plan.admits_binding(outbound.relay_id, outbound.carrier_id) {
		return prepared_carrier_retired(outbound)
	}
	carrier_id := carrier.id()
	if carrier_id != outbound.carrier_id {
		return CarrierSendResult{ ok: false, trace_id: outbound.trace_id, frame_id: outbound.frame_id, error: 'relay_carrier_mismatch:${carrier_id}' }
	}
	connected := carrier.connected()
	// id()/connected() are external callbacks and may replace the registry.
	// Recheck at admission after them, then complete on the captured carrier.
	if !outbound.plan.admits_binding(outbound.relay_id, outbound.carrier_id) {
		return prepared_carrier_retired(outbound)
	}
	if !connected {
		return CarrierSendResult{
			ok:       false
			trace_id: outbound.trace_id
			frame_id: outbound.frame_id
			error:    'relay_carrier_not_connected:${carrier_id}'
		}
	}
	return carrier.send(outbound.frame)
}

fn prepared_carrier_retired(outbound OutboundOutcome) CarrierSendResult {
	return CarrierSendResult{ ok: false, trace_id: outbound.trace_id, frame_id: outbound.frame_id, error: 'relay_carrier_ownership_changed:${outbound.relay_id}' }
}

pub fn (mut rt Runtime) detach_binding(binding &CarrierBinding, trace_id string) CarrierDetachResult {
	return rt.carriers.unbind(binding, trace_id)
}

pub fn (mut rt Runtime) detach_carrier_if_current(relay_id string, carrier_id string, trace_id string) CarrierDetachResult {
	return rt.carriers.unregister_carrier(relay_id, carrier_id, trace_id)
}
