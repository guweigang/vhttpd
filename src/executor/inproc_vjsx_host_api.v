module executor

import json
import net.http
import os
import time
import vjsx
import x.json2

struct InProcVjsxHostApi {}

fn InProcVjsxHostApi.install_http_facade(mut ctx vjsx.Context) ! {
	facade_source := inproc_vjsx_http_facade_source.to_string()
	eval_res := ctx.eval(facade_source) or {
		eprintln('[vhttpd] ERROR: js_bootstrap eval failed: ${err.msg()}')
		return err
	}
	defer { eval_res.free() }

	ctx.end()
}

fn InProcVjsxHostApi.emit_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			if args.len == 0 {
				return ctx.js_bool(false)
			}
			kind := InProcVjsxRuntimeEvent.normalize_kind(args[0].to_string())
			if kind == '' {
				return ctx.js_bool(false)
			}
			fields := if args.len > 1 {
				InProcVjsxRuntimeEvent.fields_from_js_value(args[1])
			} else {
				map[string]string{}
			}
			mut app_ref := AppFacade(unsafe { nil })
			mut lane_id := ''
			mut request_id := ''
			mut trace_id := ''
			mut method := ''
			mut path := ''
			state.mu.@lock()
			if idx >= 0 && idx < state.hosts.len && state.hosts[idx].request_ctx.active {
				request_ctx := state.hosts[idx].request_ctx
				app_ref = request_ctx.app
				lane_id = request_ctx.lane_id
				request_id = request_ctx.request_id
				trace_id = request_ctx.trace_id
				method = request_ctx.method
				path = request_ctx.path
			}
			state.mu.unlock()
			if isnil(app_ref) {
				return ctx.js_bool(false)
			}
			mut row := map[string]string{}
			row['lane_id'] = lane_id
			row['request_id'] = request_id
			row['trace_id'] = trace_id
			row['method'] = method
			row['path'] = path
			row['executor'] = 'vjsx'
			row['provider'] = 'vjsx'
			for key, value in fields {
				row[key] = value
			}
			mut app := app_ref
			app.emit(kind, row)
			return ctx.js_bool(true)
		})
	}
}

fn InProcVjsxHostApi.snapshot_builder(state_ptr &VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	mut state := unsafe { state_ptr }
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			_ = args
			mut app_ref := AppFacade(unsafe { nil })
			mut lane_id := ''
			state.mu.@lock()
			if idx >= 0 && idx < state.hosts.len && state.hosts[idx].request_ctx.active {
				app_ref = state.hosts[idx].request_ctx.app
				lane_id = state.hosts[idx].request_ctx.lane_id
			}
			if isnil(app_ref) && !isnil(state.app_ref) {
				app_ref = state.app_ref
			}
			if lane_id == '' && idx >= 0 && idx < state.lanes.len {
				lane_id = state.lanes[idx].id
			}
			state.mu.unlock()
			if isnil(app_ref) {
				return ctx.js_undefined()
			}
			mut app := app_ref
			mut req := InProcVjsxHostSnapshotRequest{
				scope: 'lane'
				kind:  'runtime'
			}
			if args.len > 0 {
				raw := if args[0].is_string() {
					args[0].to_string().trim_space()
				} else {
					args[0].json_stringify().trim_space()
				}
				if raw != '' && raw != 'undefined' && raw != 'null' {
					req = json.decode(InProcVjsxHostSnapshotRequest, raw) or { req }
				}
			}
			if req.kind == 'app' {
				lane_executor := InProcVjsxExecutor{
					state: unsafe { state }
				}
				if req.scope == 'all_lanes' {
					raw := lane_executor.aggregate_app_lane_snapshots(mut app, lane_id, true)
					if raw.trim_space() == '' {
						return ctx.js_undefined()
					}
					return ctx.js_string(raw)
				}
				if req.scope == 'other_lanes' {
					raw := lane_executor.aggregate_app_lane_snapshots(mut app, lane_id, false)
					if raw.trim_space() == '' {
						return ctx.js_undefined()
					}
					return ctx.js_string(raw)
				}
				if lane_id == '' {
					return ctx.js_undefined()
				}
				lane := lane_executor.lane_snapshot_by_id(lane_id) or { return ctx.js_undefined() }
				raw := lane_executor.execute_snapshot_hook(mut app,
					lane_executor.lane_index_by_id(lane.id), lane) or { return ctx.js_undefined() }
				if raw.trim_space() == '' || raw.trim_space() == 'undefined'
					|| raw.trim_space() == 'null' {
					return ctx.js_undefined()
				}
				return ctx.js_string(raw)
			}
			if req.scope == 'all_lanes' {
				lane_executor := InProcVjsxExecutor{
					state: unsafe { state }
				}
				raw := lane_executor.aggregate_runtime_lane_snapshots(mut app, lane_id)
				return ctx.js_string(raw)
			}
			return ctx.js_string(json.encode(app.admin_runtime_snapshot()))
		})
	}
}

fn InProcVjsxHostApi.config_lookup(raw_json string, path string) string {
	if raw_json.trim_space() == '' {
		return ''
	}
	if path.trim_space() == '' {
		return raw_json
	}
	parsed := json2.decode[json2.Any](raw_json) or { return '' }
	mut current := parsed
	for raw_part in path.split('.') {
		part := raw_part.trim_space()
		if part == '' {
			continue
		}
		root := current.as_map()
		if part !in root {
			return ''
		}
		current = root[part] or { return '' }
	}
	return current.json_str()
}

fn InProcVjsxHostApi.session_store_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	_ = idx
	return fn [mut state] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state] (args []vjsx.Value) vjsx.Value {
			if args.len == 0 {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'missing_session_store_request'
				}))
			}
			raw := args[0].to_string().trim_space()
			if raw == '' {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'missing_session_store_request'
				}))
			}
			req := json.decode(InProcVjsxHostSessionStoreRequest, raw) or {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'invalid_session_store_request'
				}))
			}
			namespace := req.namespace.trim_space()
			key := req.key.trim_space()
			if namespace == '' {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'session_store_namespace_missing'
				}))
			}
			if key == '' && req.op != 'keys' {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'session_store_key_missing'
				}))
			}
			full_key := '${namespace}:${key}'
			return match req.op {
				'get' {
					value := state.session_store.get(full_key) or {
						return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
							ok:    true
							found: false
						}))
					}
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok:    true
						found: true
						value: value
					}))
				}
				'set' {
					if req.ttl_ms > 0 {
						state.session_store.set_with_ttl(full_key, req.value,
							req.ttl_ms * time.millisecond) or {
							return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
								error: err.msg()
							}))
						}
					} else {
						state.session_store.set(full_key, req.value) or {
							return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
								error: err.msg()
							}))
						}
					}
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok: true
					}))
				}
				'patch' {
					mut swapped := false
					if req.delete_value {
						swapped = state.session_store.compare_and_swap_delete(full_key,
							req.expected_found, req.expected_value) or {
							return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
								error: err.msg()
							}))
						}
					} else {
						swapped = state.session_store.compare_and_swap_set_with_ttl(full_key,
							req.expected_found, req.expected_value, req.value,
							req.ttl_ms * time.millisecond) or {
							return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
								error: err.msg()
							}))
						}
					}
					if !swapped {
						return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
							ok:       false
							conflict: true
						}))
					}
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok: true
					}))
				}
				'delete' {
					state.session_store.delete(full_key) or {
						return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
							error: err.msg()
						}))
					}
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok: true
					}))
				}
				'exists' {
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok:    true
						found: state.session_store.exists(full_key)
					}))
				}
				'keys' {
					prefix := '${namespace}:'
					keys :=
						state.session_store.keys().filter(it.starts_with(prefix)).map(it[prefix.len..])
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok:    true
						found: keys.len > 0
						keys:  keys
					}))
				}
				else {
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						error: 'unsupported_session_store_op:${req.op}'
					}))
				}
			}
		})
	}
}

fn InProcVjsxHostApi.config_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			mut app_ref := AppFacade(unsafe { nil })
			state.mu.@lock()
			if idx >= 0 && idx < state.hosts.len && state.hosts[idx].request_ctx.active {
				app_ref = state.hosts[idx].request_ctx.app
			}
			state.mu.unlock()
			if isnil(app_ref) {
				return ctx.js_string('')
			}
			mut app := app_ref
			path := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			return ctx.js_string(InProcVjsxHostApi.config_lookup(app.get_runtime_config_json(),
				path))
		})
	}
}

fn InProcVjsxHostApi.read_text_file_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			_ = idx
			if args.len == 0 {
				return ctx.js_string('')
			}
			path := args[0].to_string().trim_space()
			if path == '' {
				return ctx.js_string('')
			}
			mut enable_fs := false
			state.mu.@lock()
			enable_fs = state.facade.config.enable_fs
			state.mu.unlock()
			if !enable_fs {
				return ctx.js_string('')
			}
			content := os.read_file(path) or {
				resolved := os.real_path(path)
				if resolved != '' && resolved != path {
					return ctx.js_string(os.read_file(resolved) or { '' })
				}
				return ctx.js_string('')
			}
			return ctx.js_string(content)
		})
	}
}

fn InProcVjsxHostApi.find_codex_session_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			_ = idx
			if args.len == 0 {
				return ctx.js_string('')
			}
			thread_id := args[0].to_string().trim_space()
			if thread_id == '' {
				return ctx.js_string('')
			}
			mut enable_fs := false
			state.mu.@lock()
			enable_fs = state.facade.config.enable_fs
			state.mu.unlock()
			if !enable_fs {
				return ctx.js_string('')
			}
			return ctx.js_string(CodexSessionLocator.find(thread_id))
		})
	}
}

fn InProcVjsxHostApi.http_fetch_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			_ = idx
			if args.len == 0 {
				return ctx.js_string('')
			}
			raw := args[0].to_string().trim_space()
			if raw == '' {
				return ctx.js_string('')
			}
			mut enable_network := false
			state.mu.@lock()
			enable_network = state.facade.config.enable_network
			state.mu.unlock()
			if !enable_network {
				return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
					ok:    false
					error: 'network_disabled'
				}))
			}
			parsed := json.decode(InProcVjsxHostHttpFetchRequest, raw) or {
				return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
					ok:    false
					error: 'invalid_fetch_request'
				}))
			}
			url := parsed.url.trim_space()
			if url == '' {
				return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
					ok:    false
					error: 'missing_url'
				}))
			}
			method_raw := parsed.method.trim_space()
			method := match method_raw.to_upper() {
				'POST' { http.Method.post }
				'PUT' { http.Method.put }
				'PATCH' { http.Method.patch }
				'DELETE' { http.Method.delete }
				'HEAD' { http.Method.head }
				'OPTIONS' { http.Method.options }
				else { http.Method.get }
			}

			body := parsed.body
			mut header := http.new_header()
			for name, value in parsed.headers {
				header.add_custom(name, value) or {} // safe to ignore: response already committed
			}
			resp := http.fetch(http.FetchConfig{
				url:    url
				method: method
				data:   body
				header: header
			}) or {
				return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
					ok:    false
					error: err.msg()
				}))
			}
			mut response_headers := map[string]string{}
			for key in resp.header.keys() {
				response_headers[key] = resp.header.get_custom(key) or { '' }
			}
			return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
				ok:      true
				status:  resp.status_code
				body:    resp.body
				headers: response_headers
			}))
		})
	}
}

fn InProcVjsxHostApi.bridge_dispatch_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			if args.len == 0 {
				return ctx.js_string('')
			}
			raw := args[0].to_string().trim_space()
			if raw == '' {
				return ctx.js_string('')
			}
			req := json.decode(InProcVjsxHostBridgeDispatchRequest, raw) or {
				return ctx.js_string(json.encode(FeishuCardBridgeResult{
					error: 'invalid_bridge_dispatch_request'
				}))
			}
			mut app_ref := AppFacade(unsafe { nil })
			mut request_trace_id := ''
			state.mu.@lock()
			if idx >= 0 && idx < state.hosts.len && state.hosts[idx].request_ctx.active {
				app_ref = state.hosts[idx].request_ctx.app
				request_trace_id = state.hosts[idx].request_ctx.trace_id
			}
			state.mu.unlock()
			if isnil(app_ref) {
				return ctx.js_string(json.encode(FeishuCardBridgeResult{
					error: 'bridge_dispatch_app_missing'
				}))
			}
			mut app := app_ref
			summary := FeishuRuntimeEventSummary.from_payload(req.payload)
			trace_id := if req.trace_id.trim_space() != '' { req.trace_id } else { request_trace_id }
			result := app.feishu_card_bridge_dispatch_callback(req.app, trace_id, FeishuRuntimeEventSummary{
				event_id:        summary.event_id
				event_kind:      if summary.event_kind != '' { summary.event_kind } else { 'action' }
				event_type:      if req.event_type.trim_space() != '' {
					req.event_type
				} else {
					summary.event_type
				}
				message_id:      if req.message_id.trim_space() != '' {
					req.message_id
				} else {
					summary.message_id
				}
				target:          if req.target.trim_space() != '' {
					req.target
				} else {
					summary.target
				}
				target_type:     if req.target_type.trim_space() != '' {
					req.target_type
				} else {
					summary.target_type
				}
				open_message_id: summary.open_message_id
				action_tag:      summary.action_tag
			}, req.payload) or {
				return ctx.js_string(json.encode(FeishuCardBridgeResult{
					error: err.msg()
				}))
			}
			return ctx.js_string(json.encode(result))
		})
	}
}

fn InProcVjsxHostApi.websocket_dispatch_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			if args.len == 0 {
				return ctx.js_string('')
			}
			raw := args[0].to_string().trim_space()
			if raw == '' {
				return ctx.js_string('')
			}
			req := json.decode(InProcVjsxHostWebSocketDispatchRequest, raw) or {
				return ctx.js_string(json.encode(InProcVjsxHostWebSocketDispatchResponse{
					error: 'invalid_websocket_dispatch_request'
				}))
			}
			mut app_ref := AppFacade(unsafe { nil })
			state.mu.@lock()
			if idx >= 0 && idx < state.hosts.len {
				if state.hosts[idx].request_ctx.active {
					app_ref = state.hosts[idx].request_ctx.app
				} else {
					app_ref = state.hosts[idx].app_ref
				}
			}
			state.mu.unlock()
			if isnil(app_ref) {
				return ctx.js_string(json.encode(InProcVjsxHostWebSocketDispatchResponse{
					error: 'websocket_dispatch_app_missing'
				}))
			}
			mut app := app_ref
			result := app.execute_websocket_dispatch_commands_result(req.commands)
			if result.has_close {
				return ctx.js_string(json.encode(InProcVjsxHostWebSocketDispatchResponse{
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
				}))
			}
			return ctx.js_string(json.encode(InProcVjsxHostWebSocketDispatchResponse{
				ok:       true
				failures: result.failures
			}))
		})
	}
}

fn InProcVjsxHostApi.builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return vjsx.host_object(vjsx.HostObjectField{
		name:  'emit'
		value: InProcVjsxHostApi.emit_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'snapshot'
		value: InProcVjsxHostApi.snapshot_builder(state, idx)
	}, vjsx.HostObjectField{
		name:  'sessionStore'
		value: InProcVjsxHostApi.session_store_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'config'
		value: InProcVjsxHostApi.config_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'readTextFile'
		value: InProcVjsxHostApi.read_text_file_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'findCodexSessionPath'
		value: InProcVjsxHostApi.find_codex_session_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'httpFetch'
		value: InProcVjsxHostApi.http_fetch_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'bridgeDispatch'
		value: InProcVjsxHostApi.bridge_dispatch_builder(mut state, idx)
	}, vjsx.HostObjectField{
		name:  'websocketDispatch'
		value: InProcVjsxHostApi.websocket_dispatch_builder(mut state, idx)
	})
}

fn InProcVjsxHostApi.install(mut ctx vjsx.Context, mut state VjsxExecutorState, idx int) {
	ctx.install_host_api(vjsx.HostApiConfig{
		globals: [
			vjsx.HostGlobalBinding{
				name:  'vhttpdHost'
				value: InProcVjsxHostApi.builder(mut state, idx)
			},
		]
	})
}
