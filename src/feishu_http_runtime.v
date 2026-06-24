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

fn feishu_json_response(req FeishuHttpRequest, mut app App, mut ctx Context, status int, body string, callback string, instance string) veb.Result {
	return feishu_response(req, mut app, mut ctx, status, {
		'content-type': 'application/json; charset=utf-8'
	}, body, callback, instance)
}

fn feishu_response(req FeishuHttpRequest, mut app App, mut ctx Context, status int, headers map[string]string, body string, callback string, instance string) veb.Result {
	mut event_metadata := {
		'provider': 'feishu'
	}
	if callback != '' {
		event_metadata['callback'] = callback
	}
	if instance != '' {
		event_metadata['instance'] = instance
	}
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request('POST',
		req.path, req.path, '', if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } },
		req.req_id, req.trace_id, req.start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(status,
		headers, body), event_metadata), none)
}
