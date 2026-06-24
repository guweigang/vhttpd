module main

import dispatch
import time
import veb

struct AdminDataPlaneRequest {
	path     string
	req_id   string
	trace_id string
	start_ms i64
}

fn admin_data_plane_request(ctx Context, default_path string) AdminDataPlaneRequest {
	path := if ctx.req.url == '' { default_path } else { ctx.req.url }
	return AdminDataPlaneRequest{
		path:     path
		req_id:   resolve_request_id(ctx, path)
		trace_id: resolve_trace_id(ctx, path)
		start_ms: time.now().unix_milli()
	}
}

fn admin_data_plane_json_response(mut app App, mut ctx Context, method string, path string, req_id string, trace_id string, start_ms i64, status int, body string, metadata map[string]string) veb.Result {
	mut event_metadata := {
		'plane': 'data'
	}
	for key, value in metadata {
		if key != '' && value != '' {
			event_metadata[key] = value
		}
	}
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request(method,
		path, path, '', if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } }, req_id,
		trace_id, start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(status, {
		'content-type': 'application/json; charset=utf-8'
	}, body), event_metadata), none)
}

fn admin_data_plane_json(mut app App, mut ctx Context, method string, req AdminDataPlaneRequest, status int, body string, metadata map[string]string) veb.Result {
	return admin_data_plane_json_response(mut app, mut ctx, method, req.path, req.req_id,
		req.trace_id, req.start_ms, status, body, metadata)
}

fn admin_data_plane_text(mut app App, mut ctx Context, method string, req AdminDataPlaneRequest, status int, body string, metadata map[string]string) veb.Result {
	return admin_data_plane_text_response(mut app, mut ctx, method, req.path, req.req_id,
		req.trace_id, req.start_ms, status, body, metadata)
}

fn admin_data_plane_text_response(mut app App, mut ctx Context, method string, path string, req_id string, trace_id string, start_ms i64, status int, body string, metadata map[string]string) veb.Result {
	mut event_metadata := {
		'plane': 'data'
	}
	for key, value in metadata {
		if key != '' && value != '' {
			event_metadata[key] = value
		}
	}
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request(method,
		path, path, '', if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } }, req_id,
		trace_id, start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(status, {
		'content-type': 'text/plain; charset=utf-8'
	}, body), event_metadata), none)
}
