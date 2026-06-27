module main

import upstream.transport
import ws
import net.websocket

struct WebSocketKernelPort {
	build_frame_fn    fn (string, string, string, map[string]string, map[string]string, string, string, string, string, string, int, string, []string, map[string]string, ws.PresenceSnapshot) transport.WorkerWebSocketFrame = unsafe { nil }
	dispatch_event_fn fn (transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse = unsafe { nil }
}

fn (mut app App) build_websocket_kernel_port() WebSocketKernelPort {
	return WebSocketKernelPort{
		build_frame_fn:    fn [mut app] (event string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, presence ws.PresenceSnapshot) transport.WorkerWebSocketFrame {
			return app.kernel_websocket_dispatch_frame(event, method, path, query, headers,
				remote_addr, req_id, trace_id, opcode, data, code, reason, rooms, metadata,
				presence.room_members, presence.member_metadata, presence.room_counts,
				presence.presence_users)
		}
		dispatch_event_fn: fn [mut app] (frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
			return app.kernel_dispatch_websocket_event(frame)
		}
	}
}

fn (mut runtime WebSocketRuntime) build_context(kernel WebSocketKernelPort) ws.RuntimeContext {
	return ws.RuntimeContext{
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
		register_conn_fn:    fn [mut runtime] (conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &ws.DispatchConnState) {
			runtime.state.register_conn(conn_id, worker_socket, method, req_id, trace_id, path,
				query, headers, remote_addr, client, lifecycle)
		}
		conn_open_fn:        fn [mut runtime] (conn_id string) bool {
			return runtime.state.conn_open(conn_id)
		}
		mark_closing_fn:     fn [mut runtime] (conn_id string) bool {
			return runtime.state.mark_closing(conn_id)
		}
		flush_pending_fn:    fn [mut runtime] (conn_id string) {
			runtime.state.flush_pending(conn_id)
		}
		cleanup_conn_fn:     fn [mut runtime] (conn_id string) {
			runtime.state.cleanup_conn(conn_id)
		}
		unregister_conn_fn:  fn [mut runtime] (conn_id string) {
			runtime.state.unregister_conn(conn_id)
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
		command_result_fn:   fn [mut runtime] (commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
			return runtime.execute_commands(commands)
		}
		followup_failure_fn: websocket_dispatch_followup_failures
		close_target_fn:     fn [mut runtime] (conn_id string, code int, reason string) {
			ws.hub_close_target(mut runtime.state, conn_id, code, reason)
		}
	}
}

fn (mut app App) build_websocket_runtime_context() ws.RuntimeContext {
	kernel := app.build_websocket_kernel_port()
	return app.websocket.build_context(kernel)
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
