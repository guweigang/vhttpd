module main

import net.websocket
import time
import relay
import ws

struct RelayAgentRuntime {}

fn (mut app App) build_relay_agent_runtime_context() ws.RelayAgentRuntimeContext {
	return ws.RelayAgentRuntimeContext{
		websocket_rt:       app.build_websocket_runtime_context()
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
				for dispatch_outcome in app.dispatch_and_send_relay_ingress_frame(relay_id,
					relay_agent_carrier_id(relay_id), outcome.inbound.frame, now_ms) {
					app.emit('relay.pipeline.dispatch',
						relay_pipeline_dispatch_event_fields(dispatch_outcome))
				}
			}
			return outcome
		}
		disconnected_fn:    fn [mut app] (descriptor relay.RelayDescriptor, reason string, now_ms i64) {
			agent := app.relay.mark_agent_failed(descriptor.id, now_ms, reason) or { return }
			app.emit('relay.agent.disconnected', relay.agent_state_event_fields(agent))
		}
		reconnect_delay_fn: fn [mut app] (descriptor relay.RelayDescriptor, trace_id string, now_ms i64) int {
			delay_ms := app.relay.agent_reconnect_delay_ms(descriptor.id, now_ms) or {
				descriptor.reconnect_delay_ms
			}
			app.emit('relay.agent.reconnect_scheduled', relay.event_fields('agent.reconnect_scheduled',
				trace_id, {
				'relay_id': descriptor.id
				'delay_ms': '${delay_ms}'
			}))
			return delay_ms
		}
		attach_carrier_fn:  fn [mut app] (descriptor relay.RelayDescriptor, carrier_id string, trace_id string) {
			result := app.relay.attach_carrier(descriptor.id, carrier_id, trace_id)
			app.emit('relay.carrier.attach', relay.carrier_attach_event_fields(result))
		}
		detach_carrier_fn:  fn [mut app] (descriptor relay.RelayDescriptor, _ string, trace_id string) {
			result := app.relay.detach_carrier(descriptor.id, trace_id)
			app.emit('relay.carrier.detach', relay.carrier_detach_event_fields(result))
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

fn RelayAgentRuntime.run_once(ctx ws.RelayAgentRuntimeContext, descriptor relay.RelayDescriptor, trace_id string) {
	websocket_rt := ctx.websocket_rt
	attempt := ctx.prepare_attempt(descriptor, trace_id, time.now().unix_milli())
	if !attempt.ok {
		return
	}
	mut client := websocket.new_client(attempt.url,
		read_timeout:  60 * time.second
		write_timeout: 60 * time.second
	) or {
		ctx.on_disconnected(descriptor, 'client:${err}', time.now().unix_milli())
		return
	}
	mut state := &RelayAgentSocketState{
		ctx:        ctx
		descriptor: descriptor
	}
	client.on_message_ref(relay_agent_message_cb, state)
	client.on_error_ref(relay_agent_error_cb, state)
	client.on_close_ref(relay_agent_close_cb, state)
	client.connect() or {
		ctx.on_disconnected(descriptor, 'connect:${err}', time.now().unix_milli())
		return
	}
	carrier_id := relay_agent_carrier_id(descriptor.id)
	mut lifecycle := &ws.DispatchConnState{}
	websocket_rt.register_conn(carrier_id, '', 'WEBSOCKET', trace_id, trace_id, descriptor.url,
		map[string]string{}, map[string]string{}, '', client, lifecycle)
	lifecycle.mark_open()
	websocket_rt.flush_pending(carrier_id)
	ctx.on_carrier_attached(descriptor, carrier_id, trace_id)
	defer {
		ctx.on_carrier_detached(descriptor, carrier_id, trace_id)
		websocket_rt.mark_closing(carrier_id)
		if lifecycle.begin_cleanup() {
			websocket_rt.cleanup_conn(carrier_id)
		}
	}
	client.write_string(attempt.hello_payload) or {
		ctx.on_disconnected(descriptor, 'hello:${err}', time.now().unix_milli())
		return
	}
	client.listen() or { ctx.on_disconnected(descriptor, 'listen:${err}', time.now().unix_milli()) }
}

fn relay_agent_carrier_id(relay_id string) string {
	return 'agent:${relay_id}'
}

fn relay_agent_attempt_trace_id(trace_prefix string, relay_id string, attempt int) string {
	if trace_prefix != '' {
		return '${trace_prefix}:${relay_id}:${attempt}'
	}
	return 'relay-agent:${relay_id}:${attempt}'
}

fn RelayAgentRuntime.run_loop(ctx ws.RelayAgentRuntimeContext, descriptor relay.RelayDescriptor, trace_prefix string) {
	mut attempt := 0
	for {
		trace_id := relay_agent_attempt_trace_id(trace_prefix, descriptor.id, attempt)
		RelayAgentRuntime.run_once(ctx, descriptor, trace_id)
		delay_ms := ctx.reconnect_delay_ms(descriptor, trace_id, time.now().unix_milli())
		if delay_ms < 0 {
			return
		}
		time.sleep(delay_ms * time.millisecond)
		attempt++
	}
}

fn relay_agent_autostart_enabled(descriptor relay.RelayDescriptor) bool {
	return descriptor.mode == .agent && (descriptor.options.bools['autostart'] or { false })
}

fn (mut app App) start_relay_agents_once(trace_prefix string) int {
	ctx := app.build_relay_agent_runtime_context()
	mut started := 0
	for descriptor in app.relay.agent_descriptors() {
		if !relay_agent_autostart_enabled(descriptor) {
			continue
		}
		go RelayAgentRuntime.run_loop(ctx, descriptor, trace_prefix)
		started++
	}
	return started
}

@[heap]
struct RelayAgentSocketState {
pub mut:
	ctx        ws.RelayAgentRuntimeContext
	descriptor relay.RelayDescriptor
}

fn relay_agent_message_cb(mut client websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &RelayAgentSocketState(ref) }
	RelayAgentRuntime.handle_message(state.ctx, state.descriptor, mut client, msg)!
}

fn relay_agent_error_cb(mut _client websocket.Client, err string, ref voidptr) ! {
	mut state := unsafe { &RelayAgentSocketState(ref) }
	state.ctx.on_disconnected(state.descriptor, 'error:${err}', time.now().unix_milli())
}

fn relay_agent_close_cb(mut _client websocket.Client, code int, reason string, ref voidptr) ! {
	mut state := unsafe { &RelayAgentSocketState(ref) }
	state.ctx.on_disconnected(state.descriptor, 'close:${code}:${reason}', time.now().unix_milli())
}
