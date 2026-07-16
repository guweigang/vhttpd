module main

import api.mcp.protocol as mcp_protocol
import dispatch
import time
import upstream.transport

pub struct McpExchangeContext {
pub:
	request_id       string
	trace_id         string
	ingress          string
	pipeline         string
	session_id       string
	path             string
	remote_addr      string
	protocol_version string
}

pub fn mcp_exchange_identity(ctx McpExchangeContext, suffix string) dispatch.ExchangeIdentity {
	base_id := if ctx.session_id.trim_space() != '' {
		ctx.session_id.trim_space()
	} else if ctx.request_id.trim_space() != '' {
		ctx.request_id.trim_space()
	} else {
		'mcp'
	}
	return dispatch.ExchangeIdentity{
		id:         '${base_id}:${suffix}'
		request_id: ctx.request_id
		trace_id:   ctx.trace_id
		parent_id:  base_id
	}
}

fn mcp_protocol_version(ctx McpExchangeContext, fallback string) string {
	if ctx.protocol_version.trim_space() != '' {
		return ctx.protocol_version.trim_space()
	}
	if fallback.trim_space() != '' {
		return fallback.trim_space()
	}
	return mcp_protocol.Session.default_protocol_version()
}

fn mcp_session_id(ctx McpExchangeContext, fallback string) string {
	if ctx.session_id.trim_space() != '' {
		return ctx.session_id.trim_space()
	}
	if fallback.trim_space() != '' {
		return fallback.trim_space()
	}
	if ctx.request_id.trim_space() != '' {
		return ctx.request_id.trim_space()
	}
	return 'mcp'
}

fn mcp_context_with_session(ctx McpExchangeContext, fallback string) McpExchangeContext {
	return McpExchangeContext{
		...ctx
		session_id: mcp_session_id(ctx, fallback)
	}
}

pub fn mcp_dispatch_request_exchange(req transport.WorkerMcpDispatchRequest, ctx McpExchangeContext) dispatch.Exchange {
	req_ctx := McpExchangeContext{
		...ctx
		request_id:       if req.request_id != '' { req.request_id } else { ctx.request_id }
		trace_id:         if req.trace_id != '' { req.trace_id } else { ctx.trace_id }
		session_id:       if req.session_id != '' { req.session_id } else { ctx.session_id }
		path:             if req.path != '' { req.path } else { ctx.path }
		remote_addr:      if req.remote_addr != '' { req.remote_addr } else { ctx.remote_addr }
		protocol_version: mcp_protocol_version(ctx, req.protocol_version)
	}
	mut metadata := map[string]string{}
	metadata['mcp.source'] = 'worker'
	metadata['mcp.event'] = req.event
	metadata['mcp.protocol_version'] = req_ctx.protocol_version
	metadata['mcp.session_id'] = req_ctx.session_id
	metadata['mcp.accept'] = req.accept
	metadata['mcp.content_type'] = req.content_type
	if req.client_capabilities_json != '' {
		metadata['mcp.client_capabilities'] = req.client_capabilities_json
	}
	return dispatch.Exchange{
		identity:      mcp_exchange_identity(req_ctx, 'request')
		kind:          .request
		ingress:       ctx.ingress
		pipeline:      ctx.pipeline
		created_at_ms: time.now().unix_milli()
		headers:       req.headers.clone()
		metadata:      metadata
		payload:       dispatch.RequestPayload{
			method:      req.http_method
			path:        req_ctx.path
			body:        if req.jsonrpc_raw != '' { req.jsonrpc_raw } else { req.body }
			remote_addr: req_ctx.remote_addr
		}
	}
}

pub fn mcp_dispatch_response_exchange(resp transport.WorkerMcpDispatchResponse, ctx McpExchangeContext) dispatch.Exchange {
	resp_ctx := mcp_context_with_session(McpExchangeContext{
		...ctx
		protocol_version: mcp_protocol_version(ctx, resp.protocol_version)
	}, resp.session_id)
	mut metadata := map[string]string{}
	metadata['mcp.source'] = 'worker'
	metadata['mcp.event'] = resp.event
	metadata['mcp.handled'] = if resp.handled { 'true' } else { 'false' }
	metadata['mcp.protocol_version'] = resp_ctx.protocol_version
	metadata['mcp.session_id'] = resp_ctx.session_id
	metadata['mcp.message_count'] = '${resp.messages.len}'
	metadata['mcp.command_count'] = '${resp.commands.len}'
	if resp.error_class != '' {
		metadata['error_class'] = resp.error_class
	}
	return dispatch.Exchange{
		identity:      mcp_exchange_identity(resp_ctx, 'response')
		kind:          .response
		ingress:       ctx.ingress
		pipeline:      ctx.pipeline
		created_at_ms: time.now().unix_milli()
		headers:       resp.headers.clone()
		metadata:      metadata
		payload:       dispatch.ResponsePayload{
			status: if resp.status > 0 { resp.status } else { 200 }
			body:   resp.body
		}
	}
}

pub fn mcp_session_stream_open_exchange(session_id string, protocol_version string, ctx McpExchangeContext) dispatch.Exchange {
	session_ctx := mcp_context_with_session(McpExchangeContext{
		...ctx
		protocol_version: mcp_protocol_version(ctx, protocol_version)
	}, session_id)
	mut metadata := map[string]string{}
	metadata['mcp.source'] = 'runtime'
	metadata['mcp.event'] = 'session_stream_open'
	metadata['mcp.protocol_version'] = session_ctx.protocol_version
	metadata['mcp.session_id'] = session_ctx.session_id
	metadata['session_protocol'] = 'mcp'
	metadata['session_transport'] = 'sse'
	return dispatch.Exchange{
		identity:      mcp_exchange_identity(session_ctx, 'stream-open')
		kind:          .stream_open
		ingress:       ctx.ingress
		pipeline:      ctx.pipeline
		created_at_ms: time.now().unix_milli()
		headers:       {
			'content-type':         'text/event-stream'
			'x-accel-buffering':    'no'
			'mcp-session-id':       session_ctx.session_id
			'mcp-protocol-version': session_ctx.protocol_version
		}
		metadata:      metadata
		payload:       dispatch.StreamPayload{
			session_id: session_ctx.session_id
		}
	}
}

pub fn mcp_session_message_exchange(ctx McpExchangeContext, message string, metadata map[string]string) dispatch.Exchange {
	session_ctx := mcp_context_with_session(ctx, '')
	mut event_metadata := metadata.clone()
	event_metadata['mcp.source'] = 'runtime'
	event_metadata['mcp.event'] = 'session_message'
	event_metadata['mcp.session_id'] = session_ctx.session_id
	return dispatch.Exchange{
		identity:      mcp_exchange_identity(session_ctx, 'message')
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

pub fn mcp_session_close_exchange(ctx McpExchangeContext, reason string, metadata map[string]string) dispatch.Exchange {
	session_ctx := mcp_context_with_session(ctx, '')
	mut event_metadata := metadata.clone()
	event_metadata['mcp.source'] = 'runtime'
	event_metadata['mcp.event'] = 'session_close'
	event_metadata['mcp.session_id'] = session_ctx.session_id
	if reason != '' {
		event_metadata['mcp.reason'] = reason
	}
	return dispatch.Exchange{
		identity:      mcp_exchange_identity(session_ctx, 'close')
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
