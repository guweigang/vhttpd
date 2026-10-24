module main

import log
import net.websocket
import relay
import time
import sync
import upstream.transport
import ws

@[heap]
struct RelayWebSocketBridgeState {
pub mut:
	relay_runtime   &relay.Runtime                 @[required]
	dispatch_host   RelayIngressDispatchHost       @[required]
	emit_fn         fn (string, map[string]string) @[required]
	lifecycle       &ws.DispatchConnState          @[required]
	websocket_rt    ws.RelaySessionContext         @[required]
	descriptor      relay.RelayDescriptor
	conn_id         string
	method          string
	path            string
	query           map[string]string
	headers         map[string]string
	remote_addr     string
	request_id      string
	trace_id        string
	carrier_mu      sync.Mutex
	carrier_binding ?&relay.CarrierBinding
}

fn relay_websocket_attached_cb(mut sc websocket.ServerClient, ref voidptr) ! {
	mut state := unsafe { &RelayWebSocketBridgeState(ref) }
	state.websocket_rt.register_conn(state.conn_id, '', state.method, state.request_id,
		state.trace_id, state.path, state.query, state.headers, state.remote_addr, sc.client,
		state.lifecycle)
	state.lifecycle.mark_open()
	state.websocket_rt.flush_pending(state.conn_id)
	log.info('[vhttpd] relay websocket attached path=${state.path} relay_id=${state.descriptor.id} carrier_id=${state.conn_id} trace_id=${state.trace_id} request_id=${state.request_id}')
	state.emit_fn('relay.websocket.attached', relay_websocket_event_fields({
		'relay_event': 'websocket.attached'
		'trace_id':    state.trace_id
	}, state))
}

fn relay_websocket_message_cb(mut ws_client websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &RelayWebSocketBridgeState(ref) }
	if !state.lifecycle.can_process_messages() {
		return
	}
	opcode, payload, supported := ws.dispatch_payload_from_message(msg)
	if !supported {
		state.lifecycle.begin_worker_close()
		ws_client.close(1003, 'Only text and binary frames are supported')!
		return
	}
	// Probe uses ping, never hello: older servers ignore it without binding a carrier.
	if probe := relay.decode_frame(payload) {
		if probe.kind == .ping && probe.metadata['purpose'] == 'connection-test-v1' {
			ack := relay.connection_probe_ack(probe, state.descriptor) or { relay.WireFrame{ kind: .error, id: 'probe-rejected', trace_id: probe.trace_id, channel_id: 'probe', body: 'connection_test_rejected' } }
			state.websocket_rt.send_to(state.conn_id, relay.encode_frame(ack)!, 'text')
			return
		}
	}
	outcome := relay_websocket_receive(mut state, opcode, payload)
	log.info('[vhttpd] relay websocket message action=${outcome.action} path=${state.path} relay_id=${state.descriptor.id} carrier_id=${state.conn_id} frame_id=${outcome.frame_id} trace_id=${outcome.trace_id} request_id=${state.request_id}')
	state.emit_fn('relay.inbound', relay_websocket_event_fields(relay.inbound_event_fields(outcome),
		state))
	if outcome.action == .forwarded {
		if relay_frame_should_dispatch_pipeline(outcome.frame) {
			mut host := state.dispatch_host
			for dispatch_outcome in host.dispatch_and_send_relay_ingress_frame(state.descriptor.id,
				state.conn_id, outcome.frame, time.now().unix_milli()) {
				state.emit_fn('relay.pipeline.dispatch', relay_websocket_event_fields(relay_pipeline_dispatch_event_fields(dispatch_outcome),
					state))
			}
		}
	}
	if outcome.action == .registered {
		if mismatch := relay_registration_path_mismatch(state, outcome) {
			relay_websocket_detach(mut state)
			state.emit_fn('relay.inbound', relay_websocket_event_fields(relay.inbound_event_fields(mismatch),
				state))
			send_relay_rejection(state, mismatch)
			state.lifecycle.begin_worker_close()
			ws_client.close(1008, mismatch.error)!
			return
		}
		state.emit_fn('relay.registration', relay_websocket_event_fields(relay.registration_event_fields(outcome.registration),
			state))
		send_relay_registration_ack(state, outcome)
		return
	}
	if outcome.action == .rejected {
		send_relay_rejection(state, outcome)
		state.lifecycle.begin_worker_close()
		ws_client.close(1008, if outcome.error != '' {
			outcome.error
		} else {
			'relay frame rejected'
		})!
	}
}

fn relay_websocket_close_cb(mut _ws_client websocket.Client, reported_code int, reported_reason string, ref voidptr) ! {
	mut state := unsafe { &RelayWebSocketBridgeState(ref) }
	code, reason := state.lifecycle.close_details(reported_code, reported_reason)
	should_process, _ := state.lifecycle.begin_peer_close()
	if !should_process {
		return
	}
	detached := relay_websocket_detach(mut state)
	log.info('[vhttpd] relay websocket closed path=${state.path} relay_id=${state.descriptor.id} carrier_id=${state.conn_id} trace_id=${state.trace_id} request_id=${state.request_id} code=${code} reason=${reason} detached=${detached.removed}')
	state.emit_fn('relay.carrier.detach', relay_websocket_event_fields(relay.carrier_detach_event_fields(detached),
		state))
	relay_websocket_finalize(mut state)
}

fn relay_websocket_finalize(mut state RelayWebSocketBridgeState) {
	state.websocket_rt.mark_closing(state.conn_id, state.lifecycle)
	state.lifecycle.mark_closing()
	relay_websocket_detach(mut state)
	if state.lifecycle.begin_cleanup() {
		state.websocket_rt.cleanup_conn(state.conn_id, state.lifecycle)
	}
}

// Serialize publication with finalization so a close cannot miss a newly
// acquired binding. Registry cleanup itself compares exact binding identity.
fn relay_websocket_receive(mut state RelayWebSocketBridgeState, opcode string, payload string) relay.InboundOutcome {
	state.carrier_mu.@lock()
	defer { state.carrier_mu.unlock() }
	if !state.lifecycle.can_process_messages() {
		return relay.InboundOutcome{ action: .ignored, carrier_id: state.conn_id }
	}
	outcome := ws.receive_relay_websocket_payload_for(mut state.relay_runtime, state.conn_id, opcode, payload, state.descriptor.channel_buffer, state.descriptor.id)
	if binding := outcome.carrier_binding { state.carrier_binding = binding }
	return outcome
}

fn relay_websocket_detach(mut state RelayWebSocketBridgeState) relay.CarrierDetachResult {
	state.carrier_mu.@lock()
	binding := state.carrier_binding
	state.carrier_binding = none
	state.carrier_mu.unlock()
	if owned := binding { return state.relay_runtime.detach_binding(owned, state.trace_id) }
	return relay.CarrierDetachResult{ relay_id: state.descriptor.id, carrier_id: state.conn_id, trace_id: state.trace_id, error: 'relay_carrier_not_registered:${state.descriptor.id}' }
}

fn send_relay_registration_ack(state &RelayWebSocketBridgeState, outcome relay.InboundOutcome) {
	if isnil(state) {
		return
	}
	raw := relay.encode_frame(relay.registration_ack_frame(outcome.registration)) or { return }
	state.websocket_rt.send_to(state.conn_id, raw, 'text')
}

fn send_relay_rejection(state &RelayWebSocketBridgeState, outcome relay.InboundOutcome) {
	if isnil(state) {
		return
	}
	raw := relay.encode_frame(relay.WireFrame{
		version:    relay.wire_version
		kind:       .error
		id:         if outcome.frame_id != '' {
			'relay-error:${outcome.frame_id}'
		} else {
			'relay-error'
		}
		trace_id:   if outcome.trace_id != '' { outcome.trace_id } else { 'unknown' }
		channel_id: if outcome.forwarding.channel_id != '' {
			outcome.forwarding.channel_id
		} else {
			'unknown'
		}
		body:       outcome.error
	}) or { return }
	state.websocket_rt.send_to(state.conn_id, raw, 'text')
}

fn relay_websocket_path_descriptor(runtime &relay.Runtime, path string) ?relay.RelayDescriptor {
	normalized_path, _ := transport.normalize_request_target(path)
	return runtime.hub_relay_by_path(normalized_path)
}

fn relay_registration_path_mismatch(state &RelayWebSocketBridgeState, outcome relay.InboundOutcome) ?relay.InboundOutcome {
	if isnil(state) {
		return none
	}
	if outcome.action != .registered {
		return none
	}
	if outcome.relay_id == state.descriptor.id {
		return none
	}
	return relay.InboundOutcome{
		action:     .rejected
		relay_id:   outcome.relay_id
		carrier_id: outcome.carrier_id
		trace_id:   outcome.trace_id
		frame_id:   outcome.frame_id
		error:      'relay_websocket_relay_mismatch:${outcome.relay_id}:${state.descriptor.id}'
	}
}

fn relay_websocket_event_fields(fields map[string]string, state &RelayWebSocketBridgeState) map[string]string {
	mut out := fields.clone()
	if isnil(state) {
		return out
	}
	if out['trace_id'] == '' {
		out['trace_id'] = state.trace_id
	}
	out['request_id'] = state.request_id
	out['path'] = state.path
	out['relay_id'] = state.descriptor.id
	out['carrier_id'] = state.conn_id
	return out
}
