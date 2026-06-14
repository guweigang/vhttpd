module executor

import json
import os
import time
import upstream.transport
import vjsx

struct InProcVjsxWebSocketJs {}

fn InProcVjsxWebSocketJs.value_from_json(ctx &vjsx.Context, raw string) vjsx.Value {
	if raw.trim_space() == '' {
		return ctx.js_object()
	}
	return ctx.json_parse(raw)
}

fn InProcVjsxWebSocketJs.log_args(args []vjsx.Value) string {
	mut parts := []string{cap: args.len}
	for arg in args {
		parts << arg.to_string()
	}
	return parts.join(' ')
}

fn InProcVjsxWebSocketJs.runtime(ctx &vjsx.Context, runtime_meta InProcVjsxRuntimeMeta, runtime_config_json string, mut app AppFacade) vjsx.Value {
	mut runtime := ctx.js_object()
	minimal_runtime := os.getenv('VHTTPD_VJSX_WS_MINIMAL_RUNTIME').trim_space().to_lower() in [
		'1',
		'true',
		'yes',
		'on',
	]
	mut capabilities := ctx.js_object()
	capabilities.set('http', false)
	capabilities.set('fetch', false)
	capabilities.set('bridgeDispatch', false)
	capabilities.set('websocketUpstream', false)
	capabilities.set('websocketDispatch', true)
	capabilities.set('fs', false)
	capabilities.set('process', false)
	capabilities.set('network', false)
	runtime.set('provider', runtime_meta.provider)
	runtime.set('executor', runtime_meta.executor)
	runtime.set('dispatchKind', 'websocket')
	runtime.set('laneId', runtime_meta.lane_id)
	runtime.set('requestId', runtime_meta.request_id)
	runtime.set('traceId', runtime_meta.trace_id)
	runtime.set('appEntry', runtime_meta.app_entry)
	runtime.set('moduleRoot', runtime_meta.module_root)
	runtime.set('runtimeProfile', runtime_meta.runtime_profile)
	runtime.set('threadCount', runtime_meta.thread_count)
	runtime.set('capabilities', capabilities)
	mut request := ctx.js_object()
	request.set('id', runtime_meta.request_id)
	request.set('traceId', runtime_meta.trace_id)
	request.set('method', runtime_meta.method)
	request.set('path', runtime_meta.path)
	request.set('url', runtime_meta.path)
	request.set('target', runtime_meta.request_target)
	request.set('href', runtime_meta.request_target)
	request.set('origin', '')
	request.set('scheme', runtime_meta.request_scheme)
	request.set('host', runtime_meta.request_host)
	request.set('port', runtime_meta.request_port)
	request.set('protocolVersion', runtime_meta.request_protocol_version)
	request.set('remoteAddr', runtime_meta.request_remote_addr)
	request.set('ip', runtime_meta.request_remote_addr)
	request.set('server', InProcVjsxWebSocketJs.value_from_json(ctx,
		json.encode(runtime_meta.request_server)))
	runtime.set('request', request)
	runtime.set('method', runtime_meta.method)
	runtime.set('path', runtime_meta.path)
	runtime.set('runtimeInitError', '')
	if minimal_runtime {
		return runtime
	}
	runtime.set('now', ctx.js_function(fn [ctx] (args []vjsx.Value) vjsx.Value {
		_ = args
		return ctx.js_i64(time.now().unix_milli())
	}))
	runtime.set('log', ctx.js_function(fn [ctx, runtime_meta] (args []vjsx.Value) vjsx.Value {
		println('[vhttpd] ${runtime_meta.lane_id} ${runtime_meta.request_id} ${runtime_meta.trace_id} ${InProcVjsxWebSocketJs.log_args(args)}')
		return ctx.js_undefined()
	}))
	runtime.set('warn', ctx.js_function(fn [ctx, runtime_meta] (args []vjsx.Value) vjsx.Value {
		eprintln('[vhttpd] ${runtime_meta.lane_id} ${runtime_meta.request_id} ${runtime_meta.trace_id} ${InProcVjsxWebSocketJs.log_args(args)}')
		return ctx.js_undefined()
	}))
	runtime.set('error', ctx.js_function(fn [ctx, runtime_meta] (args []vjsx.Value) vjsx.Value {
		eprintln('[vhttpd] ${runtime_meta.lane_id} ${runtime_meta.request_id} ${runtime_meta.trace_id} ${InProcVjsxWebSocketJs.log_args(args)}')
		return ctx.js_undefined()
	}))
	runtime.set('config', ctx.js_function(fn [ctx, runtime_config_json] (args []vjsx.Value) vjsx.Value {
		path := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
		fallback := if args.len > 1 { args[1].dup_value() } else { ctx.js_undefined() }
		raw := InProcVjsxHostApi.config_lookup(runtime_config_json, path)
		if raw.trim_space() == '' {
			return fallback
		}
		return ctx.js_string(raw)
	}))
	runtime.set('getConfig', ctx.js_function(fn [ctx, runtime_config_json] (args []vjsx.Value) vjsx.Value {
		path := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
		fallback := if args.len > 1 { args[1].dup_value() } else { ctx.js_undefined() }
		raw := InProcVjsxHostApi.config_lookup(runtime_config_json, path)
		if raw.trim_space() == '' {
			return fallback
		}
		return ctx.json_parse(raw)
	}))
	runtime.set('sessionStore', ctx.js_function(fn [ctx] (args []vjsx.Value) vjsx.Value {
		namespace := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
		mut store := ctx.js_object()
		store.set('namespace', namespace)
		store.set('get', ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			key := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			fallback := if args.len > 1 { args[1].dup_value() } else { ctx.js_undefined() }
			if namespace == '' {
				return fallback
			}
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if host_api.is_undefined() || !host_api.is_object() || !host_api.has('sessionStore') {
				return fallback
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return fallback
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'get'
				key:       key
			}))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return fallback }
			defer {
				resp_raw.free()
			}
			resp := json.decode(InProcVjsxHostSessionStoreResponse, resp_raw.to_string()) or {
				return fallback
			}
			if !resp.ok || !resp.found || resp.value.trim_space() == '' {
				return fallback
			}
			return ctx.json_parse(resp.value)
		}))
		store.set('set', ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			if namespace == '' || args.len == 0 {
				return ctx.js_bool(false)
			}
			key := args[0].to_string().trim_space()
			value := if args.len > 1 { args[1].json_stringify() } else { 'null' }
			mut ttl_ms := i64(0)
			if args.len > 2 && args[2].is_object() && args[2].has('ttlMs') {
				ttl_ms = args[2].get('ttlMs').to_i64()
			}
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if host_api.is_undefined() || !host_api.is_object() || !host_api.has('sessionStore') {
				return ctx.js_bool(false)
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return ctx.js_bool(false)
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'set'
				key:       key
				value:     value
				ttl_ms:    ttl_ms
			}))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return ctx.js_bool(false) }
			defer {
				resp_raw.free()
			}
			resp := json.decode(InProcVjsxHostSessionStoreResponse, resp_raw.to_string()) or {
				return ctx.js_bool(false)
			}
			return ctx.js_bool(resp.ok)
		}))
		store.set('delete', ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			key := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if namespace == '' || host_api.is_undefined() || !host_api.is_object()
				|| !host_api.has('sessionStore') {
				return ctx.js_bool(false)
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return ctx.js_bool(false)
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'delete'
				key:       key
			}))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return ctx.js_bool(false) }
			defer {
				resp_raw.free()
			}
			resp := json.decode(InProcVjsxHostSessionStoreResponse, resp_raw.to_string()) or {
				return ctx.js_bool(false)
			}
			return ctx.js_bool(resp.ok)
		}))
		store.set('exists', ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			key := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if namespace == '' || host_api.is_undefined() || !host_api.is_object()
				|| !host_api.has('sessionStore') {
				return ctx.js_bool(false)
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return ctx.js_bool(false)
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'exists'
				key:       key
			}))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return ctx.js_bool(false) }
			defer {
				resp_raw.free()
			}
			resp := json.decode(InProcVjsxHostSessionStoreResponse, resp_raw.to_string()) or {
				return ctx.js_bool(false)
			}
			return ctx.js_bool(resp.ok && resp.found)
		}))
		store.set('keys', ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			fallback := if args.len > 0 { args[0].dup_value() } else { ctx.js_array() }
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if namespace == '' || host_api.is_undefined() || !host_api.is_object()
				|| !host_api.has('sessionStore') {
				return fallback
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return fallback
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'keys'
			}))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return fallback }
			defer {
				resp_raw.free()
			}
			resp := json.decode(InProcVjsxHostSessionStoreResponse, resp_raw.to_string()) or {
				return fallback
			}
			if !resp.ok || resp.value.trim_space() == '' {
				return fallback
			}
			return ctx.json_parse(resp.value)
		}))
		return store
	}))
	runtime.set('websocketDispatch', ctx.js_function(fn [ctx, mut app] (args []vjsx.Value) vjsx.Value {
		fallback := if args.len > 1 { args[1].dup_value() } else { ctx.js_undefined() }
		if args.len == 0 {
			return fallback
		}
		raw := args[0].json_stringify().trim_space()
		if raw == '' || raw == 'undefined' || raw == 'null' {
			return fallback
		}
		req_raw := if raw.starts_with('[') {
			'{"commands":${raw}}'
		} else {
			decoded := json.decode(InProcVjsxHostWebSocketDispatchRequest, raw) or {
				InProcVjsxHostWebSocketDispatchRequest{}
			}
			if decoded.commands.len > 0 {
				raw
			} else {
				'{"commands":[${raw}]}'
			}
		}
		req := json.decode(InProcVjsxHostWebSocketDispatchRequest, req_raw) or { return fallback }
		result := app.execute_websocket_dispatch_commands_result(req.commands)
		response := if result.has_close {
			InProcVjsxHostWebSocketDispatchResponse{
				ok:              true
				has_close:       true
				close_code:      result.close_frame.code
				close_reason:    result.close_frame.reason
				close_target_id: if result.close_frame.target_id != '' {
					result.close_frame.target_id
				} else {
					result.close_frame.id
				}
				failures:        result.failures
			}
		} else {
			InProcVjsxHostWebSocketDispatchResponse{
				ok:       true
				failures: result.failures
			}
		}
		return ctx.json_parse(json.encode(response))
	}))
	return runtime
}

fn InProcVjsxWebSocketJs.frame(ctx &vjsx.Context, frame transport.WorkerWebSocketFrame, runtime vjsx.Value) vjsx.Value {
	mut js_frame := ctx.js_object()
	js_frame.set('mode', if frame.mode != '' { frame.mode } else { 'websocket_dispatch' })
	js_frame.set('event', if frame.event != '' { frame.event } else { 'message' })
	js_frame.set('id', frame.id)
	js_frame.set('path', frame.path)
	js_frame.set('query', InProcVjsxWebSocketJs.value_from_json(ctx, json.encode(frame.query)))
	js_frame.set('headers', InProcVjsxWebSocketJs.value_from_json(ctx, json.encode(frame.headers)))
	js_frame.set('remoteAddr', frame.remote_addr)
	js_frame.set('requestId', frame.request_id)
	js_frame.set('traceId', frame.trace_id)
	js_frame.set('targetId', frame.target_id)
	js_frame.set('metadata',
		InProcVjsxWebSocketJs.value_from_json(ctx, json.encode(frame.metadata)))
	js_frame.set('status', frame.status)
	js_frame.set('code', frame.code)
	js_frame.set('reason', frame.reason)
	js_frame.set('opcode', frame.opcode)
	js_frame.set('data', frame.data)
	js_frame.set('error', frame.error)
	js_frame.set('errorClass', frame.error_class)
	js_frame.set('runtime', runtime)
	return js_frame
}
