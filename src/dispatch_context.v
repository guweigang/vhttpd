module main

import session_handle
import worker_protocol

pub struct DispatchContext {
pub:
	session  session_handle.SessionHandle
	payload  string
	metadata map[string]string
	event    string
}

pub fn DispatchContext.from_websocket_upstream(req worker_protocol.WorkerWebSocketUpstreamDispatchRequest) DispatchContext {
	return DispatchContext{
		session:  session_handle.SessionHandle.from_websocket_upstream(req)
		payload:  req.payload
		metadata: req.metadata.clone()
		event:    req.event_type
	}
}

pub fn DispatchContext.from_stream_dispatch(req worker_protocol.StreamDispatchRequest) DispatchContext {
	return DispatchContext.from_stream_dispatch_provider(req, 'php-worker')
}

pub fn DispatchContext.from_stream_dispatch_provider(req worker_protocol.StreamDispatchRequest, provider string) DispatchContext {
	return DispatchContext{
		session: session_handle.SessionHandle.from_stream_dispatch_provider(req, provider)
		payload: req.body
		metadata: {
			'method': req.method
			'path': req.path
			'strategy': req.strategy
		}
		event: req.event
	}
}

pub fn DispatchContext.from_mcp_dispatch(req worker_protocol.WorkerMcpDispatchRequest) DispatchContext {
	return DispatchContext.from_mcp_dispatch_provider(req, 'php-worker')
}

pub fn DispatchContext.from_mcp_dispatch_provider(req worker_protocol.WorkerMcpDispatchRequest, provider string) DispatchContext {
	return DispatchContext{
		session: session_handle.SessionHandle.from_mcp_dispatch_provider(req, provider)
		payload: req.body
		metadata: {
			'http_method': req.http_method
			'path': req.path
			'protocol_version': req.protocol_version
		}
		event: req.event
	}
}

pub fn DispatchContext.from_websocket_dispatch(frame worker_protocol.WorkerWebSocketFrame) DispatchContext {
	return DispatchContext.from_websocket_dispatch_provider(frame, 'php-worker')
}

pub fn DispatchContext.from_websocket_dispatch_provider(frame worker_protocol.WorkerWebSocketFrame, provider string) DispatchContext {
	return DispatchContext{
		session: session_handle.SessionHandle.from_websocket_dispatch_provider(frame, provider)
		payload: frame.data
		metadata: {
			'path': frame.path
			'opcode': frame.opcode
		}
		event: frame.event
	}
}
