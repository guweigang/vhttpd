module main

import transport
import executor
import dispatch

pub type DispatchContext = executor.DispatchContext

pub fn DispatchContext.from_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) DispatchContext {
	return dispatch.dispatch_context_from_websocket_upstream(req)
}

pub fn DispatchContext.from_stream_dispatch(req transport.StreamDispatchRequest) DispatchContext {
	return dispatch.dispatch_context_from_stream_dispatch(req)
}

pub fn DispatchContext.from_stream_dispatch_provider(req transport.StreamDispatchRequest, provider string) DispatchContext {
	return dispatch.dispatch_context_from_stream_dispatch_provider(req, provider)
}

pub fn DispatchContext.from_mcp_dispatch(req transport.WorkerMcpDispatchRequest) DispatchContext {
	return dispatch.dispatch_context_from_mcp_dispatch(req)
}

pub fn DispatchContext.from_mcp_dispatch_provider(req transport.WorkerMcpDispatchRequest, provider string) DispatchContext {
	return dispatch.dispatch_context_from_mcp_dispatch_provider(req, provider)
}

pub fn DispatchContext.from_websocket_dispatch(frame transport.WorkerWebSocketFrame) DispatchContext {
	return dispatch.dispatch_context_from_websocket_dispatch(frame)
}

pub fn DispatchContext.from_websocket_dispatch_provider(frame transport.WorkerWebSocketFrame, provider string) DispatchContext {
	return dispatch.dispatch_context_from_websocket_dispatch_provider(frame, provider)
}
