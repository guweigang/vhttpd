module main

import json
import os
import time
import veb
import veb.request_id
import upstream.transport

pub struct Context {
	veb.Context
	request_id.RequestIdContext
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

fn runtime_trace(label string, fields map[string]string) {
	mut row := map[string]string{}
	row['ts'] = time.now().format_ss_milli()
	row['label'] = label
	row['pid'] = '${os.getpid()}'
	for k, v in fields {
		row[k] = v
	}
	mut f := os.open_append('/tmp/vhttpd_runtime_trace.log') or { return }
	defer {
		f.close()
	}
	f.writeln(json.encode(row)) or {}
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
	if kind in ['server.started', 'server.failed', 'server.stopped', 'admin.started', 'admin.failed',
		'internal_admin.started', 'internal_admin.error', 'worker.select.failed'] {
		runtime_trace('emit.${kind}', fields)
	}
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
