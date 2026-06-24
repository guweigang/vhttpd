module main

import admin
import dispatch
import json
import time
import veb

struct FeishuHttpRequest {
	path     string
	req_id   string
	trace_id string
	start_ms i64
}

fn FeishuHttpRequest.from_context(ctx Context, default_path string) FeishuHttpRequest {
	path := if ctx.req.url == '' { default_path } else { ctx.req.url }
	return FeishuHttpRequest{
		path:     path
		req_id:   HttpRequestIdentity.request_id(ctx, path)
		trace_id: HttpRequestIdentity.trace_id(ctx, path)
		start_ms: time.now().unix_milli()
	}
}

fn (req FeishuHttpRequest) prepare_json(mut ctx Context) {
	ctx.set_custom_header('x-vhttpd-trace-id', req.trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
}

fn (req FeishuHttpRequest) emit_success(mut app App, method string, event_path string, plane string, callback string, instance string) {
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
	if callback != '' {
		fields['callback'] = callback
	}
	if instance != '' {
		fields['provider'] = 'feishu'
		fields['instance'] = instance
	}
	app.emit('http.request', fields)
}

fn feishu_admin_error(req FeishuHttpRequest, mut app App, mut ctx Context, status int, error string) veb.Result {
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request('POST',
		req.path, req.path, '', if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } },
		req.req_id, req.trace_id, req.start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(status, {
		'content-type': 'application/json; charset=utf-8'
	}, json.encode(admin.AdminErrorResponse{
		error: error
	})), {
		'provider': 'feishu'
		'error':    error
	}), none)
}
