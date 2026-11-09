module main

import memidle
import upstream.transport
import ws
import connection_runtime
import net.websocket

struct WebSocketKernelPort {
	owner             ?WebSocketKernelHost
	emit_fn           fn (string, map[string]string) = unsafe { nil }
	build_frame_fn    fn (string, string, string, map[string]string, map[string]string, string, string, string, string, string, int, string, []string, map[string]string, ws.PresenceSnapshot) transport.WorkerWebSocketFrame = unsafe { nil }
	dispatch_event_fn fn (transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse = unsafe { nil }
}

interface WebSocketKernelHost {
	emit(kind string, fields map[string]string)
	build_frame(event string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, presence ws.PresenceSnapshot) transport.WorkerWebSocketFrame
	dispatch_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse
}

pub fn (kernel WebSocketKernelPort) emit(kind string, fields map[string]string) {
	if kernel.emit_fn != unsafe { nil } {
		kernel.emit_fn(kind, fields)
		return
	}
	if owner := kernel.owner {
		owner.emit(kind, fields)
		return
	}
	panic('websocket kernel operation missing: emit')
}

pub fn (kernel WebSocketKernelPort) build_frame(event string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, presence ws.PresenceSnapshot) transport.WorkerWebSocketFrame {
	if kernel.build_frame_fn != unsafe { nil } {
		return kernel.build_frame_fn(event, method, path, query, headers, remote_addr, req_id, trace_id, opcode, data, code, reason, rooms, metadata, presence)
	}
	if owner := kernel.owner {
		return owner.build_frame(event, method, path, query, headers, remote_addr, req_id, trace_id, opcode, data, code, reason, rooms, metadata, presence)
	}
	panic('websocket kernel operation missing: build_frame')
}

pub fn (kernel WebSocketKernelPort) dispatch_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	memidle.begin()
	defer { memidle.end() }
	if kernel.dispatch_event_fn != unsafe { nil } { return kernel.dispatch_event_fn(frame) }
	if owner := kernel.owner { return owner.dispatch_event(frame) }
	panic('websocket kernel operation missing: dispatch_event')
}

// Context objects retain their owner through ordinary GC references. Creating
// one must not allocate native closure trampolines for every connection/command.
struct WebSocketContextHost {
	runtime &WebSocketRuntime
	kernel  WebSocketKernelPort
}

fn (mut runtime WebSocketRuntime) build_context(kernel WebSocketKernelPort) ws.RuntimeContext {
	return ws.RuntimeContext{ owner: ws.RuntimePort(&WebSocketContextHost{ runtime: &runtime, kernel: kernel }) }
}

pub fn (host WebSocketContextHost) dispatch_targets(room string, except_id string) []ws.HubDispatchTarget {
	mut runtime := host.runtime

	return ws.hub_dispatch_targets(mut runtime.state, room, except_id)
}

pub fn (host WebSocketContextHost) presence(conn_id string) ws.PresenceSnapshot {
	mut runtime := host.runtime

	room_members, member_metadata, room_counts, presence_users :=
		runtime.state.presence_snapshot(conn_id)
	return ws.PresenceSnapshot{
		room_members:    room_members
		member_metadata: member_metadata
		room_counts:     room_counts
		presence_users:  presence_users
	}
}

pub fn (host WebSocketContextHost) rooms(conn_id string) []string {
	mut runtime := host.runtime

	return runtime.state.rooms_snapshot(conn_id)
}

pub fn (host WebSocketContextHost) metadata(conn_id string) map[string]string {
	mut runtime := host.runtime

	return runtime.state.meta_snapshot(conn_id)
}

pub fn (host WebSocketContextHost) register_conn(conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &ws.DispatchConnState, serving ?&ws.IngressRun) {
	mut runtime := host.runtime

	runtime.state.register_owned_dispatch_conn(conn_id, worker_socket, method, req_id, trace_id, path,
		query, headers, remote_addr, client, lifecycle, serving, ws.EventDispatch{ owner: host.kernel })
}

pub fn (host WebSocketContextHost) conn_open(conn_id string) bool {
	mut runtime := host.runtime

	return runtime.state.conn_open(conn_id)
}

pub fn (host WebSocketContextHost) mark_closing(conn_id string, lifecycle &ws.DispatchConnState) bool {
	mut runtime := host.runtime

	return runtime.state.mark_owned_closing(conn_id, lifecycle)
}

pub fn (host WebSocketContextHost) flush_pending(conn_id string) {
	mut runtime := host.runtime

	runtime.state.flush_pending(conn_id)
}

pub fn (host WebSocketContextHost) can_cleanup(id string, lifecycle &ws.DispatchConnState) bool {
	mut runtime := host.runtime

	return runtime.state.can_cleanup_owned(id, lifecycle)
}

pub fn (host WebSocketContextHost) cleanup_conn(conn_id string, lifecycle &ws.DispatchConnState) {
	mut runtime := host.runtime

	runtime.state.cleanup_owned(conn_id, lifecycle)
}

pub fn (host WebSocketContextHost) unregister_conn(conn_id string, lifecycle &ws.DispatchConnState) {
	mut runtime := host.runtime

	runtime.state.unregister_owned(conn_id, lifecycle)
}

pub fn (host WebSocketContextHost) send_to(conn_id string, data string, opcode string) bool {
	mut runtime := host.runtime

	return ws.hub_send_to(mut runtime.state, conn_id, data, opcode)
}

pub fn (host WebSocketContextHost) join(conn_id string, room string) bool {
	mut runtime := host.runtime

	return runtime.state.join(conn_id, room)
}

pub fn (host WebSocketContextHost) leave(conn_id string, room string) bool {
	mut runtime := host.runtime

	return runtime.state.leave(conn_id, room)
}

pub fn (host WebSocketContextHost) set_meta(conn_id string, key string, value string) bool {
	mut runtime := host.runtime

	return runtime.state.set_meta(conn_id, key, value)
}

pub fn (host WebSocketContextHost) clear_meta(conn_id string, key string) bool {
	mut runtime := host.runtime

	return runtime.state.clear_meta(conn_id, key)
}

pub fn (host WebSocketContextHost) broadcast(room string, data string, opcode string, except_id string) int {
	mut runtime := host.runtime

	return ws.hub_broadcast(mut runtime.state, room, data, opcode, except_id)
}

pub fn (host WebSocketContextHost) command_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	mut runtime := host.runtime

	return runtime.execute_commands(commands, host.kernel)
}

pub fn (host WebSocketContextHost) close_owned_target(id string, lifecycle &ws.DispatchConnState, code int, reason string) {
	mut runtime := host.runtime

	ws.hub_close_owned_target(mut runtime.state, id, lifecycle, code, reason)
}

pub fn (host WebSocketContextHost) close_target(conn_id string, code int, reason string) {
	mut runtime := host.runtime

	ws.hub_close_target(mut runtime.state, conn_id, code, reason)
}

pub fn (host WebSocketContextHost) emit(kind string, fields map[string]string) {
	host.kernel.emit(kind, fields)
}

pub fn (host WebSocketContextHost) build_frame(event string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, presence ws.PresenceSnapshot) transport.WorkerWebSocketFrame {
	return host.kernel.build_frame(event, method, path, query, headers, remote_addr, req_id, trace_id, opcode, data, code, reason, rooms, metadata, presence)
}

pub fn (host WebSocketContextHost) dispatch_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	return host.kernel.dispatch_event(frame)
}

pub fn (host WebSocketContextHost) followup_failure(conn_id string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, failures []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame {
	return websocket_dispatch_followup_failures(conn_id, method, path, query, headers, remote_addr, req_id, trace_id, failures)
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
