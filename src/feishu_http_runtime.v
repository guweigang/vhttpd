module main

import admin
import json
import net.http
import feishu
import veb

struct FeishuHttpRequest {
	path     string
	req_id   string
	trace_id string
}

struct FeishuHttpResponse {}

fn FeishuHttpRequest.from_context(ctx Context, default_path string) FeishuHttpRequest {
	path := if ctx.req.url == '' { default_path } else { ctx.req.url }
	return FeishuHttpRequest{
		path:     path
		req_id:   HttpRequestIdentity.request_id(ctx, path)
		trace_id: HttpRequestIdentity.trace_id(ctx, path)
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

fn FeishuHttpResponse.admin_error(mut ctx Context, status int, error string) veb.Result {
	ctx.res.set_status(http.status_from_int(status))
	return ctx.text(json.encode(admin.AdminErrorResponse{
		error: error
	}))
}

fn FeishuHttpResponse.send_failure(mut ctx Context, status int, error string) veb.Result {
	ctx.res.set_status(http.status_from_int(status))
	return ctx.text(json.encode(feishu.SendMessageResult{
		ok:    false
		error: error
	}))
}
