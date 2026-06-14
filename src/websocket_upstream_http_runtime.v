module main

import admin
import json
import net.http
import upstream
import veb

struct WebSocketUpstreamHttpRequest {
	path     string
	req_id   string
	trace_id string
}

struct WebSocketUpstreamHttpResponse {}

fn WebSocketUpstreamHttpRequest.from_context(ctx Context, default_path string) WebSocketUpstreamHttpRequest {
	path := if ctx.req.url == '' { default_path } else { ctx.req.url }
	return WebSocketUpstreamHttpRequest{
		path:     path
		req_id:   HttpRequestIdentity.request_id(ctx, path)
		trace_id: HttpRequestIdentity.trace_id(ctx, path)
	}
}

fn (req WebSocketUpstreamHttpRequest) prepare_json(mut ctx Context) {
	ctx.set_custom_header('x-vhttpd-trace-id', req.trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
}

fn (req WebSocketUpstreamHttpRequest) emit_success(mut app App, method string, event_path string, plane string) {
	mut fields := {
		'method':     method
		'path':       event_path
		'status':     '200'
		'request_id': req.req_id
		'trace_id':   req.trace_id
	}
	if plane != '' {
		fields['plane'] = plane
	}
	app.emit('http.request', fields)
}

fn WebSocketUpstreamHttpResponse.admin_error(mut ctx Context, status int, error string) veb.Result {
	ctx.res.set_status(http.status_from_int(status))
	return ctx.text(json.encode(admin.AdminErrorResponse{
		error: error
	}))
}

fn WebSocketUpstreamHttpResponse.send_failure(mut ctx Context, status int, error string) veb.Result {
	ctx.res.set_status(http.status_from_int(status))
	return ctx.text(json.encode(upstream.UpstreamSendResult.failure(error)))
}
