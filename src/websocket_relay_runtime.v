module main

import log
import net
import net.websocket
import relay
import time
import upstream.transport
import ws

@[heap]
struct RelayWebSocketBridgeState {
pub mut:
	app          &App                  = unsafe { nil }
	lifecycle    &ws.DispatchConnState = unsafe { nil }
	websocket_rt ws.RuntimeContext
	descriptor   relay.RelayDescriptor
	conn_id      string
	method       string
	path         string
	query        map[string]string
	headers      map[string]string
	remote_addr  string
	request_id   string
	trace_id     string
}

fn handle_relay_websocket_session(mut app App, mut client_conn net.TcpConn, key string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, descriptor relay.RelayDescriptor) {
	mut ws_server := websocket.new_server(.ip, 0, '')
	mut lifecycle := &ws.DispatchConnState{}
	websocket_rt := app.build_websocket_runtime_context()
	mut state := &RelayWebSocketBridgeState{
		app:          unsafe { &app }
		lifecycle:    lifecycle
		websocket_rt: websocket_rt
		descriptor:   descriptor
		conn_id:      req_id
		method:       method
		path:         path
		query:        query.clone()
		headers:      headers.clone()
		remote_addr:  remote_addr
		request_id:   req_id
		trace_id:     trace_id
	}
	ws_server.on_attached_ref(relay_websocket_attached_cb, state)
	ws_server.on_message_ref(relay_websocket_message_cb, state)
	ws_server.on_close_ref(relay_websocket_close_cb, state)
	defer {
		relay_websocket_finalize(state)
	}
	ws_server.handle_handshake(mut client_conn, key) or {
		log.error('[vhttpd] relay websocket handshake failed path=${path} relay_id=${descriptor.id} trace_id=${trace_id} request_id=${req_id} error=${err.msg()}')
		return
	}
}

fn relay_websocket_attached_cb(mut sc websocket.ServerClient, ref voidptr) ! {
	mut state := unsafe { &RelayWebSocketBridgeState(ref) }
	state.websocket_rt.register_conn(state.conn_id, '', state.method, state.request_id,
		state.trace_id, state.path, state.query, state.headers, state.remote_addr, sc.client,
		state.lifecycle)
	state.lifecycle.mark_open()
	state.websocket_rt.flush_pending(state.conn_id)
	log.info('[vhttpd] relay websocket attached path=${state.path} relay_id=${state.descriptor.id} carrier_id=${state.conn_id} trace_id=${state.trace_id} request_id=${state.request_id}')
	mut app := unsafe { state.app }
	app.emit('relay.websocket.attached', relay_websocket_event_fields({
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
	mut app := unsafe { state.app }
	outcome := ws.receive_relay_websocket_payload(mut app.relay, state.conn_id, opcode, payload,
		state.descriptor.channel_buffer)
	log.info('[vhttpd] relay websocket message action=${outcome.action} path=${state.path} relay_id=${state.descriptor.id} carrier_id=${state.conn_id} frame_id=${outcome.frame_id} trace_id=${outcome.trace_id} request_id=${state.request_id}')
	app.emit('relay.inbound', relay_websocket_event_fields(relay.inbound_event_fields(outcome),
		state))
	if outcome.action == .forwarded {
		for dispatch_outcome in app.dispatch_relay_ingress_frame(state.descriptor.id,
			state.conn_id, outcome.frame, time.now().unix_milli()) {
			app.emit('relay.pipeline.dispatch', relay_websocket_event_fields(relay_pipeline_dispatch_event_fields(dispatch_outcome),
				state))
		}
	}
	if outcome.action == .registered {
		if mismatch := relay_registration_path_mismatch(state, outcome) {
			app.relay.detach_carrier(outcome.relay_id, state.trace_id)
			app.emit('relay.inbound', relay_websocket_event_fields(relay.inbound_event_fields(mismatch),
				state))
			send_relay_rejection(state, mismatch)
			state.lifecycle.begin_worker_close()
			ws_client.close(1008, mismatch.error)!
			return
		}
		app.emit('relay.registration', relay_websocket_event_fields(relay.registration_event_fields(outcome.registration),
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

fn relay_websocket_close_cb(mut _ws_client websocket.Client, code int, reason string, ref voidptr) ! {
	mut state := unsafe { &RelayWebSocketBridgeState(ref) }
	should_process, _ := state.lifecycle.begin_peer_close()
	if !should_process {
		return
	}
	mut app := unsafe { state.app }
	detached := app.relay.detach_carrier(state.descriptor.id, state.trace_id)
	log.info('[vhttpd] relay websocket closed path=${state.path} relay_id=${state.descriptor.id} carrier_id=${state.conn_id} trace_id=${state.trace_id} request_id=${state.request_id} code=${code} reason=${reason} detached=${detached.removed}')
	app.emit('relay.carrier.detach', relay_websocket_event_fields(relay.carrier_detach_event_fields(detached),
		state))
	relay_websocket_finalize(state)
}

fn relay_websocket_finalize(state &RelayWebSocketBridgeState) {
	if isnil(state) {
		return
	}
	unsafe {
		mut current := state
		current.websocket_rt.mark_closing(current.conn_id)
		if current.lifecycle.begin_cleanup() {
			current.websocket_rt.cleanup_conn(current.conn_id)
		}
	}
}

fn send_relay_registration_ack(state &RelayWebSocketBridgeState, outcome relay.InboundOutcome) {
	if isnil(state) {
		return
	}
	raw := relay.encode_frame(relay.registration_ack_frame(outcome.registration)) or { return }
	unsafe {
		current := state
		current.websocket_rt.send_to(current.conn_id, raw, 'text')
	}
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
	unsafe {
		current := state
		current.websocket_rt.send_to(current.conn_id, raw, 'text')
	}
}

fn relay_websocket_path_descriptor(app &App, path string) ?relay.RelayDescriptor {
	normalized_path, _ := transport.normalize_request_target(path)
	return app.relay.hub_relay_by_path(normalized_path)
}

fn relay_registration_path_mismatch(state &RelayWebSocketBridgeState, outcome relay.InboundOutcome) ?relay.InboundOutcome {
	if isnil(state) {
		return none
	}
	if outcome.action != .registered {
		return none
	}
	unsafe {
		current := state
		if outcome.relay_id == current.descriptor.id {
			return none
		}
		return relay.InboundOutcome{
			action:     .rejected
			relay_id:   outcome.relay_id
			carrier_id: outcome.carrier_id
			trace_id:   outcome.trace_id
			frame_id:   outcome.frame_id
			error:      'relay_websocket_relay_mismatch:${outcome.relay_id}:${current.descriptor.id}'
		}
	}
}

fn relay_websocket_event_fields(fields map[string]string, state &RelayWebSocketBridgeState) map[string]string {
	mut out := fields.clone()
	if isnil(state) {
		return out
	}
	unsafe {
		current := state
		if out['trace_id'] == '' {
			out['trace_id'] = current.trace_id
		}
		out['request_id'] = current.request_id
		out['path'] = current.path
		out['relay_id'] = current.descriptor.id
		out['carrier_id'] = current.conn_id
	}
	return out
}
