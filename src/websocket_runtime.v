module main

import upstream.transport
import ws
import connection_runtime
import net.websocket

struct WebSocketKernelPort {
	emit_fn           fn (string, map[string]string) @[required]
	build_frame_fn    fn (string, string, string, map[string]string, map[string]string, string, string, string, string, string, int, string, []string, map[string]string, ws.PresenceSnapshot) transport.WorkerWebSocketFrame @[required]
	dispatch_event_fn fn (transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse @[required]
}

fn (mut runtime WebSocketRuntime) build_context(kernel WebSocketKernelPort) ws.RuntimeContext {
	return ws.RuntimeContext{
		emit_fn:             kernel.emit_fn
		dispatch_targets_fn: fn [mut runtime] (room string, except_id string) []ws.HubDispatchTarget {
			return ws.hub_dispatch_targets(mut runtime.state, room, except_id)
		}
		presence_fn:         fn [mut runtime] (conn_id string) ws.PresenceSnapshot {
			room_members, member_metadata, room_counts, presence_users :=
				runtime.state.presence_snapshot(conn_id)
			return ws.PresenceSnapshot{
				room_members:    room_members
				member_metadata: member_metadata
				room_counts:     room_counts
				presence_users:  presence_users
			}
		}
		rooms_fn:            fn [mut runtime] (conn_id string) []string {
			return runtime.state.rooms_snapshot(conn_id)
		}
		metadata_fn:         fn [mut runtime] (conn_id string) map[string]string {
			return runtime.state.meta_snapshot(conn_id)
		}
		register_conn_fn:    fn [mut runtime, kernel] (conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &ws.DispatchConnState, serving ?&ws.IngressRun) {
			runtime.state.register_owned_dispatch_conn(conn_id, worker_socket, method, req_id, trace_id, path,
				query, headers, remote_addr, client, lifecycle, serving, ws.EventDispatch{ call_fn: kernel.dispatch_event_fn })
		}
		conn_open_fn:        fn [mut runtime] (conn_id string) bool {
			return runtime.state.conn_open(conn_id)
		}
		mark_closing_fn:     fn [mut runtime] (conn_id string, lifecycle &ws.DispatchConnState) bool {
			return runtime.state.mark_owned_closing(conn_id, lifecycle)
		}
		flush_pending_fn:    fn [mut runtime] (conn_id string) {
			runtime.state.flush_pending(conn_id)
		}
		can_cleanup_fn:      fn [mut runtime] (id string, lifecycle &ws.DispatchConnState) bool {
			return runtime.state.can_cleanup_owned(id, lifecycle)
		}
		cleanup_conn_fn:     fn [mut runtime] (conn_id string, lifecycle &ws.DispatchConnState) {
			runtime.state.cleanup_owned(conn_id, lifecycle)
		}
		unregister_conn_fn:  fn [mut runtime] (conn_id string, lifecycle &ws.DispatchConnState) {
			runtime.state.unregister_owned(conn_id, lifecycle)
		}
		send_to_fn:          fn [mut runtime] (conn_id string, data string, opcode string) bool {
			return ws.hub_send_to(mut runtime.state, conn_id, data, opcode)
		}
		join_fn:             fn [mut runtime] (conn_id string, room string) bool {
			return runtime.state.join(conn_id, room)
		}
		leave_fn:            fn [mut runtime] (conn_id string, room string) bool {
			return runtime.state.leave(conn_id, room)
		}
		set_meta_fn:         fn [mut runtime] (conn_id string, key string, value string) bool {
			return runtime.state.set_meta(conn_id, key, value)
		}
		clear_meta_fn:       fn [mut runtime] (conn_id string, key string) bool {
			return runtime.state.clear_meta(conn_id, key)
		}
		broadcast_fn:        fn [mut runtime] (room string, data string, opcode string, except_id string) int {
			return ws.hub_broadcast(mut runtime.state, room, data, opcode, except_id)
		}
		build_frame_fn:      kernel.build_frame_fn
		dispatch_event_fn:   kernel.dispatch_event_fn
		command_result_fn:   fn [mut runtime, kernel] (commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
			return runtime.execute_commands(commands, kernel)
		}
		followup_failure_fn: websocket_dispatch_followup_failures
		close_owned_fn:      fn [mut runtime] (id string, lifecycle &ws.DispatchConnState, code int, reason string) {
			ws.hub_close_owned_target(mut runtime.state, id, lifecycle, code, reason)
		}
		close_target_fn:     fn [mut runtime] (conn_id string, code int, reason string) {
			ws.hub_close_target(mut runtime.state, conn_id, code, reason)
		}
	}
}

// ── Dispatch followup (stub) ──

fn websocket_dispatch_followup_failures(conn_id string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, failures []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame {
	_ = conn_id
	_ = method
	_ = path
	_ = query
	_ = headers
	_ = remote_addr
	_ = req_id
	_ = trace_id
	_ = failures
	return none
}

fn (mut runtime WebSocketRuntime) build_relay_carrier_context() ws.RelayCarrierContext {
	return ws.RelayCarrierContext{
		bind_fn: fn [mut runtime] (id string) ws.RelayCarrierTarget {
			return ws.hub_relay_carrier_target(mut runtime.state, id)
		}
	}
}

fn (mut runtime WebSocketRuntime) build_relay_session_context() ws.RelaySessionContext {
	return ws.RelaySessionContext{
		register_conn_fn: fn [mut runtime] (conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &ws.DispatchConnState, serving ?&ws.IngressRun) {
			runtime.state.register_owned_conn(conn_id, worker_socket, method, req_id, trace_id, path,
				query, headers, remote_addr, client, lifecycle, serving)
		}
		mark_closing_fn:  fn [mut runtime] (conn_id string, lifecycle &ws.DispatchConnState) bool {
			return runtime.state.mark_owned_closing(conn_id, lifecycle)
		}
		flush_pending_fn: fn [mut runtime] (conn_id string) {
			runtime.state.flush_pending(conn_id)
		}
		cleanup_conn_fn:  fn [mut runtime] (conn_id string, lifecycle &ws.DispatchConnState) {
			runtime.state.cleanup_owned(conn_id, lifecycle)
		}
		bind_outbound_fn: fn [mut runtime] (id string, lifecycle &ws.DispatchConnState, session &connection_runtime.Session) bool {
			return runtime.state.bind_outbound(id, lifecycle, session)
		}
		send_to_fn:       fn [mut runtime] (conn_id string, data string, opcode string) bool {
			return ws.hub_send_to(mut runtime.state, conn_id, data, opcode)
		}
	}
}
