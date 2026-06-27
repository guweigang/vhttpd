module ws

import relay

pub enum RelayAgentPayloadAction {
	handshake
	inbound
	rejected
}

pub struct RelayAgentPayloadOutcome {
pub:
	action    RelayAgentPayloadAction
	relay_id  string
	trace_id  string
	frame_id  string
	handshake relay.AgentHandshakeOutcome
	inbound   relay.InboundOutcome
	error     string
}

pub struct RelayAgentConnectAttempt {
pub:
	ok                 bool
	relay_id           string
	url                string
	trace_id           string
	hello_payload      string
	reconnect_delay_ms int
	agent              relay.AgentState
	fields             map[string]string
	error              string
}

pub struct RelayAgentRuntimeContext {
pub:
	websocket_rt       RuntimeContext
	prepare_attempt_fn fn (relay.RelayDescriptor, string, i64) RelayAgentConnectAttempt = unsafe { nil }
	handle_payload_fn  fn (string, string, string, i64, int) RelayAgentPayloadOutcome   = unsafe { nil }
	disconnected_fn    fn (relay.RelayDescriptor, string, i64)     = unsafe { nil }
	reconnect_delay_fn fn (relay.RelayDescriptor, string, i64) int = unsafe { nil }
	attach_carrier_fn  fn (relay.RelayDescriptor, string, string)  = unsafe { nil }
	detach_carrier_fn  fn (relay.RelayDescriptor, string, string)  = unsafe { nil }
}

pub fn (ctx RelayAgentRuntimeContext) prepare_attempt(descriptor relay.RelayDescriptor, trace_id string, now_ms i64) RelayAgentConnectAttempt {
	return ctx.prepare_attempt_fn(descriptor, trace_id, now_ms)
}

pub fn (ctx RelayAgentRuntimeContext) handle_payload(relay_id string, opcode string, payload string, now_ms i64, default_buffer_limit int) RelayAgentPayloadOutcome {
	return ctx.handle_payload_fn(relay_id, opcode, payload, now_ms, default_buffer_limit)
}

pub fn (ctx RelayAgentRuntimeContext) on_disconnected(descriptor relay.RelayDescriptor, reason string, now_ms i64) {
	ctx.disconnected_fn(descriptor, reason, now_ms)
}

pub fn (ctx RelayAgentRuntimeContext) reconnect_delay_ms(descriptor relay.RelayDescriptor, trace_id string, now_ms i64) int {
	return ctx.reconnect_delay_fn(descriptor, trace_id, now_ms)
}

pub fn (ctx RelayAgentRuntimeContext) on_carrier_attached(descriptor relay.RelayDescriptor, carrier_id string, trace_id string) {
	ctx.attach_carrier_fn(descriptor, carrier_id, trace_id)
}

pub fn (ctx RelayAgentRuntimeContext) on_carrier_detached(descriptor relay.RelayDescriptor, carrier_id string, trace_id string) {
	ctx.detach_carrier_fn(descriptor, carrier_id, trace_id)
}

pub fn build_relay_agent_hello_payload(descriptor relay.RelayDescriptor, trace_id string) !string {
	if descriptor.mode != .agent {
		return error('relay_agent_hello_requires_agent_mode:${descriptor.id}')
	}
	frame := relay.registration_hello_frame(relay.registration_request_from_descriptor(descriptor,
		trace_id))!
	return relay.encode_frame(frame)!
}

pub fn relay_agent_hello_event_fields(descriptor relay.RelayDescriptor, trace_id string) map[string]string {
	return relay.event_fields('agent.hello', trace_id, {
		'relay_id': descriptor.id
		'node_id':  descriptor.node_id
		'url':      descriptor.url
	})
}

pub fn prepare_relay_agent_connect_attempt(mut rt relay.Runtime, descriptor relay.RelayDescriptor, trace_id string, now_ms i64) RelayAgentConnectAttempt {
	agent := rt.mark_agent_connecting(descriptor.id, now_ms) or {
		return RelayAgentConnectAttempt{
			relay_id: descriptor.id
			url:      descriptor.url
			trace_id: trace_id
			error:    err.msg()
			fields:   relay.event_fields('agent.connect_failed', trace_id, {
				'relay_id': descriptor.id
				'url':      descriptor.url
				'error':    err.msg()
			})
		}
	}
	payload := build_relay_agent_hello_payload(descriptor, trace_id) or {
		return RelayAgentConnectAttempt{
			relay_id: descriptor.id
			url:      descriptor.url
			trace_id: trace_id
			agent:    agent
			error:    err.msg()
			fields:   relay.event_fields('agent.connect_failed', trace_id, {
				'relay_id': descriptor.id
				'url':      descriptor.url
				'error':    err.msg()
			})
		}
	}
	policy := relay.reconnect_policy_from_descriptor(descriptor)
	return RelayAgentConnectAttempt{
		ok:                 true
		relay_id:           descriptor.id
		url:                descriptor.url
		trace_id:           trace_id
		hello_payload:      payload
		reconnect_delay_ms: policy.initial_delay_ms
		agent:              agent
		fields:             relay.event_fields('agent.connecting', trace_id, {
			'relay_id': descriptor.id
			'node_id':  descriptor.node_id
			'url':      descriptor.url
		})
	}
}

pub fn receive_relay_agent_websocket_payload(mut rt relay.Runtime, relay_id string, opcode string, payload string, now_ms i64, default_buffer_limit int) RelayAgentPayloadOutcome {
	if opcode != '' && opcode != 'text' {
		return relay_agent_payload_rejected(relay_id, '', '',
			'relay_agent_unsupported_opcode:${opcode}')
	}
	frame := relay.decode_frame(payload) or {
		return relay_agent_payload_rejected(relay_id, '', '', err.msg())
	}
	if relay_agent_should_handle_handshake(rt, relay_id, frame) {
		handshake := rt.handle_agent_handshake_frame(relay_id, frame, now_ms)
		return RelayAgentPayloadOutcome{
			action:    .handshake
			relay_id:  relay_id
			trace_id:  handshake.trace_id
			frame_id:  handshake.frame_id
			handshake: handshake
			error:     handshake.error
		}
	}
	inbound := rt.receive_from_carrier('hub:${relay_id}', frame, default_buffer_limit)
	return RelayAgentPayloadOutcome{
		action:   .inbound
		relay_id: relay_id
		trace_id: inbound.trace_id
		frame_id: inbound.frame_id
		inbound:  inbound
		error:    inbound.error
	}
}

fn relay_agent_should_handle_handshake(rt relay.Runtime, relay_id string, frame relay.WireFrame) bool {
	if frame.kind !in [.hello_ack, .error] {
		return false
	}
	agent := rt.agents[relay_id] or { return true }
	return agent.state != .registered
}

fn relay_agent_payload_rejected(relay_id string, trace_id string, frame_id string, err string) RelayAgentPayloadOutcome {
	return RelayAgentPayloadOutcome{
		action:   .rejected
		relay_id: relay_id
		trace_id: trace_id
		frame_id: frame_id
		error:    err
	}
}

pub fn relay_agent_payload_event_fields(outcome RelayAgentPayloadOutcome) map[string]string {
	return relay.event_fields('agent_payload.${outcome.action}', outcome.trace_id, {
		'relay_id': outcome.relay_id
		'frame_id': outcome.frame_id
		'error':    outcome.error
	})
}
