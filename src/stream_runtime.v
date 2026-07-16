module main

import upstream.transport

struct HttpStreamRuntime {}

struct StreamRuntimeContext {
	emit_fn           fn (string, map[string]string) = unsafe { nil }
	dispatch_open_fn  fn (string, string, string, string, string, string, map[string]string, map[string]string) !transport.StreamDispatchResponse            = unsafe { nil }
	dispatch_next_fn  fn (string, string, string, string, string, map[string]string, map[string]string, map[string]string) !transport.StreamDispatchResponse = unsafe { nil }
	dispatch_close_fn fn (string, string, map[string]string, string) !transport.StreamDispatchResponse = unsafe { nil }
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

fn (mut app App) build_stream_runtime_context() StreamRuntimeContext {
	return StreamRuntimeContext{
		emit_fn:           fn [mut app] (kind string, fields map[string]string) {
			app.emit(kind, fields)
		}
		dispatch_open_fn:  fn [mut app] (method string, path string, body string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string) !transport.StreamDispatchResponse {
			return app.kernel_stream_dispatch_open(method, path, body, remote_addr, req_id,
				trace_id, query, headers)
		}
		dispatch_next_fn:  fn [mut app] (method string, path string, remote_addr string, req_id string, trace_id string, query map[string]string, headers map[string]string, state map[string]string) !transport.StreamDispatchResponse {
			return app.kernel_stream_dispatch_next(method, path, remote_addr, req_id, trace_id,
				query, headers, state)
		}
		dispatch_close_fn: fn [mut app] (req_id string, trace_id string, state map[string]string, reason string) !transport.StreamDispatchResponse {
			return app.kernel_stream_dispatch_close(req_id, trace_id, state, reason)
		}
	}
}
