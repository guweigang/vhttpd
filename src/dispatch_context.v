module main

pub struct DispatchContext {
pub:
	session  SessionHandle
	payload  string
	metadata map[string]string
	event    string
}

pub fn DispatchContext.from_websocket_upstream(req WorkerWebSocketUpstreamDispatchRequest) DispatchContext {
	return DispatchContext{
		session:  SessionHandle.from_websocket_upstream(req)
		payload:  req.payload
		metadata: req.metadata.clone()
		event:    req.event_type
	}
}

pub fn DispatchContext.from_stream_dispatch(req StreamDispatchRequest) DispatchContext {
	return DispatchContext{
		session: SessionHandle.from_stream_dispatch(req)
		payload: req.body
		metadata: {
			'method': req.method
			'path': req.path
			'strategy': req.strategy
		}
		event: req.event
	}
}

pub fn DispatchContext.from_mcp_dispatch(req WorkerMcpDispatchRequest) DispatchContext {
	return DispatchContext{
		session: SessionHandle.from_mcp_dispatch(req)
		payload: req.body
		metadata: {
			'http_method': req.http_method
			'path': req.path
			'protocol_version': req.protocol_version
		}
		event: req.event
	}
}

pub fn DispatchContext.from_websocket_dispatch(frame WorkerWebSocketFrame) DispatchContext {
	return DispatchContext{
		session: SessionHandle.from_websocket_dispatch(frame)
		payload: frame.data
		metadata: {
			'path': frame.path
			'opcode': frame.opcode
		}
		event: frame.event
	}
}
