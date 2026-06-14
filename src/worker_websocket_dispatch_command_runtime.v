module main

import upstream.transport
import ws

struct WorkerWebSocketDispatchCommandRuntime {}

fn WorkerWebSocketDispatchCommandRuntime.execute(rt ws.RuntimeContext, commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	mut close_frame := transport.WorkerWebSocketFrame{}
	mut has_close := false
	mut failures := []transport.WorkerWebSocketDispatchCommandFailure{}
	for cmd in commands {
		if cmd.event == 'close' && cmd.target_id == '' {
			close_frame = cmd
			has_close = true
			continue
		}
		if failure := rt.process_worker_frame(cmd) {
			failures << failure
		}
	}
	return transport.WorkerWebSocketDispatchCommandsResult{
		close_frame: close_frame
		has_close:   has_close
		failures:    failures
	}
}

fn WorkerWebSocketDispatchCommandRuntime.first_close(result transport.WorkerWebSocketDispatchCommandsResult) ?transport.WorkerWebSocketFrame {
	if result.has_close {
		return result.close_frame
	}
	return none
}

fn (mut app App) execute_websocket_dispatch_commands_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	websocket_runtime := app.build_websocket_runtime_context()
	return WorkerWebSocketDispatchCommandRuntime.execute(websocket_runtime, commands)
}

fn (mut app App) execute_websocket_dispatch_commands(commands []transport.WorkerWebSocketFrame) ?transport.WorkerWebSocketFrame {
	result := app.execute_websocket_dispatch_commands_result(commands)
	return WorkerWebSocketDispatchCommandRuntime.first_close(result)
}
