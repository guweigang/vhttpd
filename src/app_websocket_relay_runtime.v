module main

import log
import net
import relay
import ws

fn (mut app App) build_relay_websocket_state(descriptor relay.RelayDescriptor, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string) &RelayWebSocketBridgeState {
	mut control := &app.control_plane
	return &RelayWebSocketBridgeState{
		relay_runtime: &app.relay
		dispatch_host: app
		emit_fn:       fn [mut control] (kind string, fields map[string]string) {
			control.emit(kind, fields)
		}
		lifecycle:     &ws.DispatchConnState{}
		websocket_rt:  app.websocket.build_relay_session_context()
		descriptor:    descriptor
		// Request IDs are tracing input and may repeat across concurrent sockets.
		conn_id:       app.websocket.state.next_connection_id()
		method:        method
		path:          path
		query:         query.clone()
		headers:       headers.clone()
		remote_addr:   remote_addr
		request_id:    req_id
		trace_id:      trace_id
	}
}

fn handle_relay_websocket_session(mut app App, mut client_conn net.TcpConn, key string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, descriptor relay.RelayDescriptor, serving ?&ws.IngressRun) {
	mut ws_server, captured := ws.managed_server()
	mut state := app.build_relay_websocket_state(descriptor, method, path, query, headers, remote_addr, req_id, trace_id)
	state.websocket_rt = state.websocket_rt.with_ingress(serving)
	ws_server.on_attached_ref(relay_websocket_attached_cb, state)
	ws_server.on_message_ref(relay_websocket_message_cb, state)
	ws_server.on_close_ref(relay_websocket_close_cb, state)
	defer {
		relay_websocket_finalize(mut state)
	}
	ws.managed_handshake(mut ws_server, mut client_conn, key, captured) or {
		log.error('[vhttpd] relay websocket handshake failed path=${path} relay_id=${descriptor.id} trace_id=${trace_id} request_id=${req_id} error=${err.msg()}')
		return
	}
}

fn run_relay_websocket_session(mut run ws.IngressRun, mut app App, mut client_conn net.TcpConn, key string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, descriptor relay.RelayDescriptor) {
	defer { run.finish() }
	if run.stopped() {
		client_conn.close() or {}
		return
	}
	handle_relay_websocket_session(mut app, mut client_conn, key, method, path, query, headers, remote_addr, req_id, trace_id, descriptor, &run)
}
