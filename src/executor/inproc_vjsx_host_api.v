module executor

import json
import os
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
