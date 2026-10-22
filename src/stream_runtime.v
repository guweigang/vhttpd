module main

import upstream.transport
import executor
import veb

struct HttpStreamRuntime {}

struct StreamRuntimeContext {
	render_open_failure_fn fn (mut Context, HttpIngressRequest, executor.KernelStreamDispatchFailure) veb.Result @[required]
	emit_fn                fn (string, map[string]string) @[required]
	dispatch_open_fn       fn (string, string, string, string, string, string, map[string]string, map[string]string) !transport.StreamDispatchResponse            @[required]
	dispatch_next_fn       fn (string, string, string, string, string, map[string]string, map[string]string, map[string]string) !transport.StreamDispatchResponse @[required]
	dispatch_close_fn      fn (string, string, map[string]string, string) !transport.StreamDispatchResponse @[required]
}

fn (rt StreamRuntimeContext) emit(kind string, fields map[string]string) {
	rt.emit_fn(kind, fields)
}

fn (rt StreamRuntimeContext) dispatch_open(method string, path string, body string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string) !transport.StreamDispatchResponse {
	return rt.dispatch_open_fn(method, path, body, remote_addr, req_id, trace_id, query, headers)
}

fn (rt StreamRuntimeContext) dispatch_next(method string, path string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string, state map[string]string) !transport.StreamDispatchResponse {
	return rt.dispatch_next_fn(method, path, remote_addr, req_id, trace_id, query, headers, state)
}

fn (rt StreamRuntimeContext) dispatch_close(req_id string, trace_id string, state map[string]string, reason string) !transport.StreamDispatchResponse {
	return rt.dispatch_close_fn(req_id, trace_id, state, reason)
}
