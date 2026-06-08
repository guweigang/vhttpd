module main

import transport
import ws
import net.websocket

// ── Type aliases: main → ws ──
type WebSocketDispatchConnState = ws.DispatchConnState
type HubConn = ws.HubConn
type HubPendingMessage = ws.HubPendingMessage


type WebSocketRuntimeContext = ws.RuntimeContext
type WebSocketBridgeState = ws.BridgeState
type WebSocketDispatchBridgeState = ws.DispatchBridgeState

// ── Builder: captures App closures ──

fn (mut app App) build_websocket_runtime_context() ws.RuntimeContext {
	return ws.RuntimeContext{
		dispatch_targets_fn: fn [mut app] (room string, except_id string) []ws.HubDispatchTarget {
			return ws.hub_dispatch_targets(mut app.ws_hub, room, except_id)
		}
		presence_fn:         fn [mut app] (conn_id string) ws.PresenceSnapshot {
			room_members, member_metadata, room_counts, presence_users :=
				app.ws_hub.presence_snapshot(conn_id)
			return ws.PresenceSnapshot{
				room_members:    room_members
				member_metadata: member_metadata
				room_counts:     room_counts
				presence_users:  presence_users
			}
		}
		rooms_fn:            fn [mut app] (conn_id string) []string {
			return app.ws_hub.rooms_snapshot(conn_id)
		}
		metadata_fn:         fn [mut app] (conn_id string) map[string]string {
			return app.ws_hub.meta_snapshot(conn_id)
		}
		register_conn_fn:    fn [mut app] (conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &ws.DispatchConnState) {
			app.ws_hub.register_conn(conn_id, worker_socket, method, req_id, trace_id, path,
				query, headers, remote_addr, client, lifecycle)
		}
		mark_closing_fn:     fn [mut app] (conn_id string) bool {
			return app.ws_hub.mark_closing(conn_id)
		}
		flush_pending_fn:    fn [mut app] (conn_id string) {
			app.ws_hub.flush_pending(conn_id)
		}
		cleanup_conn_fn:     fn [mut app] (conn_id string) {
			app.ws_hub.cleanup_conn(conn_id)
		}
		unregister_conn_fn:  fn [mut app] (conn_id string) {
			app.ws_hub.unregister_conn(conn_id)
		}
		send_to_fn:          fn [mut app] (conn_id string, data string, opcode string) bool {
			return ws.hub_send_to(mut app.ws_hub, conn_id, data, opcode)
		}
		join_fn:             fn [mut app] (conn_id string, room string) bool {
			return app.ws_hub.join(conn_id, room)
		}
		leave_fn:            fn [mut app] (conn_id string, room string) bool {
			return app.ws_hub.leave(conn_id, room)
		}
		set_meta_fn:         fn [mut app] (conn_id string, key string, value string) bool {
			return app.ws_hub.set_meta(conn_id, key, value)
		}
		clear_meta_fn:       fn [mut app] (conn_id string, key string) bool {
			return app.ws_hub.clear_meta(conn_id, key)
		}
		broadcast_fn:        fn [mut app] (room string, data string, opcode string, except_id string) int {
			return ws.hub_broadcast(mut app.ws_hub, room, data, opcode, except_id)
		}
		build_frame_fn:      fn [mut app] (event string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, presence ws.PresenceSnapshot) transport.WorkerWebSocketFrame {
			return app.kernel_websocket_dispatch_frame(event, method, path, query, headers,
				remote_addr, req_id, trace_id, opcode, data, code, reason, rooms, metadata,
				presence.room_members, presence.member_metadata, presence.room_counts,
				presence.presence_users)
		}
		dispatch_event_fn:   fn [mut app] (frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
			return app.kernel_dispatch_websocket_event(frame)
		}
		command_result_fn:   fn [mut app] (commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
			return app.execute_websocket_dispatch_commands_result(commands)
		}
		followup_failure_fn: fn [mut app] (conn_id string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, failures []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame {
			return app.websocket_dispatch_followup_failures(conn_id, method, path, query, headers,
				remote_addr, req_id, trace_id, failures)
		}
		close_target_fn:     fn [mut app] (conn_id string, code int, reason string) {
			ws.hub_close_target(mut app.ws_hub, conn_id, code, reason)
		}
	}
}

// ── Dispatch followup (stub) ──

fn (mut app App) websocket_dispatch_followup_failures(conn_id string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, failures []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame {
	_ = app
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

fn (mut app App) admin_websockets_snapshot(details bool, limit int, offset int, room_filter string, conn_filter string) ws.RuntimeSnapshot {
	return ws.hub_snapshot(mut app.ws_hub, details, limit, offset, room_filter, conn_filter)
}
