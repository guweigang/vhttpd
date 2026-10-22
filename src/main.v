module main

import executor
import time
import veb
import veb.request_id
import upstream.transport

pub struct Context {
	veb.Context
	request_id.RequestIdContext
mut:
	observed_pipeline string
	// Request-owned observation state; absent for unobserved/upgrade requests.
	observed_timing          ?&executor.HttpRequestTiming
	observed_adapter_depth   int
	observed_adapter_started i64
}

@[heap]
pub struct App {
	veb.Middleware[Context]
	veb.StaticHandler
	DataPlaneRuntime
pub mut:
	control_plane ControlPlaneRuntime
	lifecycle     ProcessLifecycle
}

fn resolve_trace_id(ctx Context, path string) string {
	_, query_str := transport.normalize_request_target(path)
	query := transport.parse_query_map(query_str)
	if query['trace_id'] != '' {
		return query['trace_id']
	}
	headers := transport.header_map_from_request(ctx.req)
	for key in ['x-trace-id', 'x-request-id'] {
		if headers[key] != '' {
			return headers[key]
		}
	}
	if ctx.request_id != '' {
		return ctx.request_id
	}
	return 'vhttpd-${time.now().unix_micro()}'
}

fn resolve_request_id(ctx Context, path string) string {
	_, query_str := transport.normalize_request_target(path)
	query := transport.parse_query_map(query_str)
	if query['request_id'] != '' {
		return query['request_id']
	}
	if ctx.request_id != '' {
		return ctx.request_id
	}
	headers := transport.header_map_from_request(ctx.req)
	header_rid := headers['x-request-id']
	if header_rid != '' {
		return header_rid
	}
	return 'req-${time.now().unix_micro()}'
}

fn (mut app App) emit(kind string, fields map[string]string) {
	app.control_plane.emit(kind, fields)
}

@['/:path...'; get]
pub fn (mut app App) proxy_get(mut ctx Context, path string) veb.Result {
	return HttpIngressRuntime.route(mut app, mut ctx, 'GET', path)
}

@['/:path...'; post]
pub fn (mut app App) proxy_post(mut ctx Context, path string) veb.Result {
	return HttpIngressRuntime.route(mut app, mut ctx, 'POST', path)
}

@['/:path...'; put]
pub fn (mut app App) proxy_put(mut ctx Context, path string) veb.Result {
	return HttpIngressRuntime.route(mut app, mut ctx, 'PUT', path)
}

@['/:path...'; patch]
pub fn (mut app App) proxy_patch(mut ctx Context, path string) veb.Result {
	return HttpIngressRuntime.route(mut app, mut ctx, 'PATCH', path)
}

@['/:path...'; delete]
pub fn (mut app App) proxy_delete(mut ctx Context, path string) veb.Result {
	return HttpIngressRuntime.route(mut app, mut ctx, 'DELETE', path)
}

@['/:path...'; head]
pub fn (mut app App) proxy_head(mut ctx Context, path string) veb.Result {
	return HttpIngressRuntime.route(mut app, mut ctx, 'HEAD', path)
}

@['/:path...'; options]
pub fn (mut app App) proxy_options(mut ctx Context, path string) veb.Result {
	return HttpIngressRuntime.route(mut app, mut ctx, 'OPTIONS', path)
}
