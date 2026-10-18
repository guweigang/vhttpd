module main

import api.mcp.protocol as mcp_protocol
import executor
import upstream.transport

fn (mut app App) mcp_dispatch_route(id string) !&mcp_protocol.SessionDispatch {
	lookup := app.protocols.mcp.lookup_dispatch(id)!
	if retained := lookup.route { return retained }
	app.mu.@lock()
	state := app.engines.primary
	port := executor.logic_executor_mcp_port(state.logic_executor)
	app.mu.unlock()
	// Metadata callbacks may re-enter App or publish a replacement. The route
	// retains this state/port and validates admission again after the callback.
	provider := state.logic_executor.provider()
	mut host := SessionDispatchHost{ snapshot: new_worker_backend_request_snapshot(state, app.build_engine_lifecycle_port()) }
	mut facade := app.as_facade()
	candidate := &mcp_protocol.SessionDispatch{
		provider:   provider
		retired_fn: fn [state] () bool { return state.backend_retiring() }
		call_fn:    fn [port, mut host, mut facade] (req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
			return port.dispatch_mcp_with_worker_port(mut facade, mut host, req)
		}
	}
	return app.protocols.mcp.session_dispatch(id, candidate)
}

fn (mut app App) retire_mcp_dispatch_sessions() {
	streams := app.protocols.mcp.retire_dispatches()
	app.protocols.mcp.wait_dispatch_streams(streams)
}
