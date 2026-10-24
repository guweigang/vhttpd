module executor

import json2 as json
import vjsx

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
			access := state.request_host(idx, .request_only) or { return ctx.js_bool(false) }
			request_ctx := access.context
			mut row := map[string]string{}
			row['lane_id'] = request_ctx.lane_id
			row['request_id'] = request_ctx.request_id
			row['trace_id'] = request_ctx.trace_id
			row['method'] = request_ctx.method
			row['path'] = request_ctx.path
			row['executor'] = 'vjsx'
			row['provider'] = 'vjsx'
			for key, value in fields {
				row[key] = value
			}
			mut app := access.host
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
			access := state.request_host(idx, .executor) or { return ctx.js_undefined() }
			lane_id := access.lane_id
			mut app := access.host
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
					req = json.decode[InProcVjsxHostSnapshotRequest](raw) or { req }
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
			return ctx.js_string(json.encode(app.admin_runtime_snapshot(),
				escape_unicode: true
				time_as_unix:   true
			))
		})
	}
}
