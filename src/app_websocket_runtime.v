module main

import upstream.transport
import ws
import executor
import worker

fn (mut app App) build_websocket_kernel_port() WebSocketKernelPort {
	app.mu.@lock()
	state := app.engines.primary
	app.mu.unlock()
	return app.build_websocket_kernel_port_for_state(state)
}

fn (mut app App) build_websocket_kernel_port_for_state(state &worker.WorkerState) WebSocketKernelPort {
	port := executor.logic_executor_websocket_event_port(state.logic_executor)
	mut host := SessionDispatchHost{ snapshot: new_worker_backend_request_snapshot(state, app.build_engine_lifecycle_port()) }
	mut facade := app.as_facade()
	return WebSocketKernelPort{
		emit_fn:           fn [mut app] (kind string, fields map[string]string) {
			app.emit(kind, fields)
		}
		build_frame_fn:    fn [mut app] (event string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, presence ws.PresenceSnapshot) transport.WorkerWebSocketFrame {
			return app.kernel_websocket_dispatch_frame(event, method, path, query, headers,
				remote_addr, req_id, trace_id, opcode, data, code, reason, rooms, metadata,
				presence.room_members, presence.member_metadata, presence.room_counts,
				presence.presence_users)
		}
		dispatch_event_fn: fn [port, mut facade, mut host] (frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
			return port.dispatch_event_with_worker_port(mut facade, mut host, frame)
		}
	}
}

fn (mut app App) build_websocket_runtime_context() ws.RuntimeContext {
	kernel := app.build_websocket_kernel_port()
	return app.websocket.build_context(kernel)
}

fn (mut app App) build_websocket_runtime_context_for_state(state &worker.WorkerState) ws.RuntimeContext {
	return app.websocket.build_context(app.build_websocket_kernel_port_for_state(state))
}
