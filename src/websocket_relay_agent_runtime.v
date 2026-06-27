module main

import net.websocket
import time
import relay
import ws

struct RelayAgentRuntime {}

fn (mut app App) build_relay_agent_runtime_context() ws.RelayAgentRuntimeContext {
	return ws.RelayAgentRuntimeContext{
		prepare_attempt_fn: fn [mut app] (descriptor relay.RelayDescriptor, trace_id string, now_ms i64) ws.RelayAgentConnectAttempt {
			attempt := ws.prepare_relay_agent_connect_attempt(mut app.relay, descriptor, trace_id,
				now_ms)
			app.emit(if attempt.ok { 'relay.agent.connecting' } else { 'relay.agent.connect_failed' },
				attempt.fields)
			return attempt
		}
		handle_payload_fn:  fn [mut app] (relay_id string, opcode string, payload string, now_ms i64, default_buffer_limit int) ws.RelayAgentPayloadOutcome {
			outcome := ws.receive_relay_agent_websocket_payload(mut app.relay, relay_id, opcode,
				payload, now_ms, default_buffer_limit)
			app.emit('relay.agent.payload', ws.relay_agent_payload_event_fields(outcome))
			if outcome.action == .handshake {
				app.emit('relay.agent.handshake',
					relay.agent_handshake_event_fields(outcome.handshake))
			} else if outcome.action == .inbound {
				app.emit('relay.agent.inbound', relay.inbound_event_fields(outcome.inbound))
			}
			return outcome
		}
		disconnected_fn:    fn [mut app] (descriptor relay.RelayDescriptor, reason string, now_ms i64) {
			agent := app.relay.mark_agent_failed(descriptor.id, now_ms, reason) or { return }
			app.emit('relay.agent.disconnected', relay.agent_state_event_fields(agent))
		}
	}
}

fn RelayAgentRuntime.handle_message(ctx ws.RelayAgentRuntimeContext, descriptor relay.RelayDescriptor, mut _client websocket.Client, msg &websocket.Message) ! {
	opcode, payload, supported := ws.dispatch_payload_from_message(msg)
	if !supported {
		ctx.on_disconnected(descriptor, 'unsupported_opcode:${msg.opcode}', time.now().unix_milli())
		return
	}
	ctx.handle_payload(descriptor.id, opcode, payload, time.now().unix_milli(),
		descriptor.channel_buffer)
}
