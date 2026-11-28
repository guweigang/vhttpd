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
	mut host := ?SessionDispatchHost(none)
	if state.logic_executor is executor.SocketWorkerExecutor {
		host = SessionDispatchHost{ snapshot: new_worker_backend_request_snapshot(state, app.build_engine_lifecycle_port()) }
	}
	return WebSocketKernelPort{
		owner: WebSocketKernelHost(&AppWebSocketKernel{ app: &app, port: port, worker_host: host })
	}
}

// Keep the originating executor in an ordinary owned object, including when a
// connection outlives publication of a replacement engine.
struct AppWebSocketKernel {
	app         &App
	port        executor.LogicExecutorWebSocketEventPort
	worker_host ?SessionDispatchHost
}

pub fn (kernel AppWebSocketKernel) emit(kind string, fields map[string]string) {
	mut app := kernel.app
	app.emit(kind, fields)
}

pub fn (kernel AppWebSocketKernel) build_frame(event string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, presence ws.PresenceSnapshot) transport.WorkerWebSocketFrame {
	mut app := kernel.app
	return app.kernel_websocket_dispatch_frame(event, method, path, query, headers,
		remote_addr, req_id, trace_id, opcode, data, code, reason, rooms, metadata,
		presence.room_members, presence.member_metadata, presence.room_counts,
		presence.presence_users)
}

pub fn (kernel AppWebSocketKernel) dispatch_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	mut app := kernel.app
	mut facade := app.as_facade()
	if mut host := kernel.worker_host {
		return kernel.port.dispatch_event_with_worker_port(mut facade, mut host, frame)
	}
	return kernel.port.dispatch_websocket_event(mut facade, frame)
}

fn (mut app App) build_websocket_runtime_context() ws.RuntimeContext {
	kernel := app.build_websocket_kernel_port()
	return app.websocket.build_context(kernel)
}

fn (mut app App) build_websocket_runtime_context_for_state(state &worker.WorkerState) ws.RuntimeContext {
	return app.websocket.build_context(app.build_websocket_kernel_port_for_state(state))
}
