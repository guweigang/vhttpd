module relay

pub enum InboundAction {
	registered
	forwarded
	returned
	ignored
	rejected
}

pub struct InboundOutcome {
pub:
	action       InboundAction
	relay_id     string
	carrier_id   string
	trace_id     string
	frame_id     string
	frame        WireFrame
	registration RegistrationResult
	forwarding   ForwardingOutcome
	error        string
}

pub fn (mut rt Runtime) handle_inbound_frame(carrier_id string, frame WireFrame, default_buffer_limit int) InboundOutcome {
	match frame.kind {
		.hello {
			return rt.handle_inbound_registration(carrier_id, frame)
		}
		.open, .data, .end, .cancel, .error {
			source_node_id := frame.metadata['node_id'] or { carrier_id }
			forwarding := rt.handle_frame(frame, source_node_id, default_buffer_limit)
			return InboundOutcome{
				action:     if forwarding.action == .rejected {
					InboundAction.rejected
				} else if frame_is_pipeline_response(frame) {
					InboundAction.returned
				} else {
					InboundAction.forwarded
				}
				relay_id:   frame.metadata['relay_id'] or { '' }
				carrier_id: carrier_id
				trace_id:   frame.trace_id
				frame_id:   frame.id
				frame:      frame
				forwarding: forwarding
				error:      forwarding.error
			}
		}
		.hello_ack, .ping, .pong {
			return InboundOutcome{
				action:     .ignored
				carrier_id: carrier_id
				trace_id:   frame.trace_id
				frame_id:   frame.id
				frame:      frame
			}
		}
	}
}

fn (mut rt Runtime) handle_inbound_registration(carrier_id string, frame WireFrame) InboundOutcome {
	relay_id := frame.metadata['relay_id'] or { '' }
	expected_token := if descriptor := rt.descriptors[relay_id] {
		descriptor.token
	} else {
		''
	}
	result := accept_registration(frame, expected_token) or {
		return InboundOutcome{
			action:     .rejected
			relay_id:   relay_id
			carrier_id: carrier_id
			trace_id:   frame.trace_id
			frame_id:   frame.id
			frame:      frame
			error:      err.msg()
		}
	}
	if result.accepted {
		rt.register_carrier(result.relay_id, carrier_id) or {
			return InboundOutcome{
				action:       .rejected
				relay_id:     result.relay_id
				carrier_id:   carrier_id
				trace_id:     frame.trace_id
				frame_id:     frame.id
				frame:        frame
				registration: result
				error:        err.msg()
			}
		}
	}
	return InboundOutcome{
		action:       if result.accepted { InboundAction.registered } else { InboundAction.rejected }
		relay_id:     result.relay_id
		carrier_id:   carrier_id
		trace_id:     frame.trace_id
		frame_id:     frame.id
		frame:        frame
		registration: result
		error:        result.error
	}
}

pub fn inbound_event_fields(outcome InboundOutcome) map[string]string {
	return event_fields('inbound.${outcome.action}', outcome.trace_id, {
		'relay_id':   outcome.relay_id
		'carrier_id': outcome.carrier_id
		'frame_id':   outcome.frame_id
		'error':      outcome.error
	})
}
