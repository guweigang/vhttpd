module main

import dispatch
import executor
import time
import upstream.transport

pub struct WebSocketExchangeContext {
pub:
	request_id  string
	trace_id    string
	ingress     string
	pipeline    string
	session_id  string
	path        string
	remote_addr string
}

pub fn websocket_exchange_identity(ctx WebSocketExchangeContext, suffix string) dispatch.ExchangeIdentity {
	base_id := if ctx.session_id.trim_space() != '' {
		ctx.session_id.trim_space()
	} else if ctx.request_id.trim_space() != '' {
		ctx.request_id.trim_space()
	} else {
		'websocket'
	}
	return dispatch.ExchangeIdentity{
		id:         '${base_id}:${suffix}'
		request_id: ctx.request_id
		trace_id:   ctx.trace_id
		parent_id:  base_id
	}
}

fn websocket_session_id(ctx WebSocketExchangeContext, fallback string) string {
	if ctx.session_id.trim_space() != '' {
		return ctx.session_id.trim_space()
	}
	if fallback.trim_space() != '' {
		return fallback.trim_space()
	}
	if ctx.request_id.trim_space() != '' {
		return ctx.request_id.trim_space()
	}
	return 'websocket'
}

fn websocket_context_with_session(ctx WebSocketExchangeContext, fallback string) WebSocketExchangeContext {
	return WebSocketExchangeContext{
		...ctx
		session_id: websocket_session_id(ctx, fallback)
	}
}

pub fn websocket_session_open_exchange(req executor.WebSocketSessionOpenRequest, outcome executor.WebSocketSessionOpenOutcome, ctx WebSocketExchangeContext) dispatch.Exchange {
	path := if req.path != '' { req.path } else { ctx.path }
	remote_addr := if req.remote_addr != '' { req.remote_addr } else { ctx.remote_addr }
	req_id := if req.request_id != '' { req.request_id } else { ctx.request_id }
	trace_id := if req.trace_id != '' { req.trace_id } else { ctx.trace_id }
	session_ctx := websocket_context_with_session(WebSocketExchangeContext{
		...ctx
		request_id:  req_id
		trace_id:    trace_id
		path:        path
		remote_addr: remote_addr
	}, req_id)
	mut metadata := map[string]string{}
	metadata['websocket.source'] = 'worker'
	metadata['websocket.accepted'] = if outcome.accepted { 'true' } else { 'false' }
	metadata['websocket.status'] = '${if outcome.status > 0 {
		outcome.status
	} else if outcome.accepted {
		101
	} else {
		0
	}}'
	metadata['websocket.path'] = path
	metadata['websocket.remote_addr'] = remote_addr
	if outcome.socket_path != '' {
		metadata['websocket.socket_path'] = outcome.socket_path
	}
	return dispatch.Exchange{
		identity:      websocket_exchange_identity(session_ctx, 'open')
		kind:          .session_open
		ingress:       ctx.ingress
		pipeline:      ctx.pipeline
		created_at_ms: time.now().unix_milli()
		headers:       {
			'upgrade': 'websocket'
		}
		metadata:      metadata
		payload:       dispatch.SessionPayload{
			session_id: session_ctx.session_id
			message:    outcome.body
		}
	}
}

pub fn worker_websocket_frame_exchange(frame transport.WorkerWebSocketFrame, ctx WebSocketExchangeContext) dispatch.Exchange {
	session_ctx := websocket_context_with_session(ctx, if frame.id != '' {
		frame.id
	} else {
		frame.request_id
	})
	mut metadata := frame.metadata.clone()
	metadata['websocket.source'] = 'worker'
	metadata['websocket.event'] = frame.event
	if frame.opcode != '' {
		metadata['websocket.opcode'] = frame.opcode
	}
	if frame.code > 0 {
		metadata['websocket.code'] = '${frame.code}'
	}
	if frame.reason != '' {
		metadata['websocket.reason'] = frame.reason
	}
	kind := match frame.event {
		'open', 'accept' { dispatch.ExchangeKind.session_open }
		'close' { dispatch.ExchangeKind.session_close }
		else { dispatch.ExchangeKind.session_message }
	}

	suffix := match kind {
		.session_open { 'open' }
		.session_close { 'close' }
		else { 'message' }
	}

	return dispatch.Exchange{
		identity:      websocket_exchange_identity(session_ctx, suffix)
		kind:          kind
		ingress:       ctx.ingress
		pipeline:      ctx.pipeline
		created_at_ms: time.now().unix_milli()
		headers:       frame.headers.clone()
		metadata:      metadata
		payload:       dispatch.SessionPayload{
			session_id: session_ctx.session_id
			message:    if frame.data != '' { frame.data } else { frame.reason }
			rooms:      frame.rooms.clone()
		}
	}
}

pub fn websocket_session_message_exchange(ctx WebSocketExchangeContext, message string, metadata map[string]string) dispatch.Exchange {
	session_ctx := websocket_context_with_session(ctx, '')
	mut event_metadata := metadata.clone()
	event_metadata['websocket.source'] = 'runtime'
	event_metadata['websocket.event'] = 'message'
	return dispatch.Exchange{
		identity:      websocket_exchange_identity(session_ctx, 'message')
		kind:          .session_message
		ingress:       ctx.ingress
		pipeline:      ctx.pipeline
		created_at_ms: time.now().unix_milli()
		headers:       map[string]string{}
		metadata:      event_metadata
		payload:       dispatch.SessionPayload{
			session_id: session_ctx.session_id
			message:    message
		}
	}
}

pub fn websocket_session_close_exchange(ctx WebSocketExchangeContext, reason string, metadata map[string]string) dispatch.Exchange {
	session_ctx := websocket_context_with_session(ctx, '')
	mut event_metadata := metadata.clone()
	event_metadata['websocket.source'] = 'runtime'
	event_metadata['websocket.event'] = 'close'
	if reason != '' {
		event_metadata['websocket.reason'] = reason
	}
	return dispatch.Exchange{
		identity:      websocket_exchange_identity(session_ctx, 'close')
		kind:          .session_close
		ingress:       ctx.ingress
		pipeline:      ctx.pipeline
		created_at_ms: time.now().unix_milli()
		headers:       map[string]string{}
		metadata:      event_metadata
		payload:       dispatch.SessionPayload{
			session_id: session_ctx.session_id
			message:    reason
		}
	}
}
