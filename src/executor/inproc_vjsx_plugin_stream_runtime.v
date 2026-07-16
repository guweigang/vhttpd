module executor

import json
import vjsx

fn (e InProcVjsxExecutor) call_plugin_stream_once(mut app AppFacade, req PluginCallRequest, on_frame PluginStreamFrameFn) !PluginStreamCallResponse {
	e.bootstrap_placeholder()!
	lane := e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)!
	defer {
		e.release_lane(lane.id)
	}
	idx := e.lane_index_by_id(lane.id)
	if idx < 0 {
		e.record_lane_error(lane.id, 'inproc_vjsx_executor_lane_not_found')
		return error('inproc_vjsx_executor_lane_not_found')
	}
	e.ensure_lane_host(idx) or {
		e.record_lane_error(lane.id, err.msg())
		return error(err.msg())
	}
	e.run_startup_hooks(mut app, idx, lane) or {
		e.record_lane_error(lane.id, err.msg())
		return error(err.msg())
	}
	e.activate_lane_request_context(idx, mut app, lane.id, HttpLogicDispatchRequest{
		method:     req.op
		path:       '/_plugin/${req.capability}'
		trace_id:   req.trace_id
		request_id: req.request_id
	})
	defer {
		e.clear_lane_request_context(idx)
	}
	mut state := e.state
	state.mu.@lock()
	mut host := state.hosts[idx]
	state.mu.unlock()
	ctx := host.context()
	req_obj := ctx.json_parse(json.encode(req))
	defer {
		req_obj.free()
	}
	entry_kind := if req.capability.trim_space() == '' {
		'plugin'
	} else {
		req.capability.trim_space()
	}
	mut result := host.call_entry(entry_kind, req_obj) or {
		if err.msg() == 'inproc_vjsx_executor_missing_${entry_kind}_handler' {
			host.call_entry('plugin', req_obj) or {
				e.record_lane_error(lane.id, err.msg())
				return error('inproc_vjsx_executor_plugin_handler_failed:${err.msg()}')
			}
		} else {
			e.record_lane_error(lane.id, err.msg())
			return error('inproc_vjsx_executor_plugin_handler_failed:${err.msg()}')
		}
	}
	defer {
		result.free()
	}
	if host.session.is_streamable_value(result) {
		completed := host.session.stream_value(result, fn [on_frame] (frame vjsx.Value) !bool {
			raw := frame.json_stringify()
			return on_frame(raw)!
		}) or {
			e.record_lane_error(lane.id, err.msg())
			return error('inproc_vjsx_executor_plugin_stream_failed:${err.msg()}')
		}
		e.record_lane_success(lane.id)
		return PluginStreamCallResponse{
			streamed: true
			response: PluginCallResponse{
				ok:     true
				result: '{"streamed":true,"completed":${completed}}'
			}
		}
	}
	resolved := host.resolve_value(result) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_plugin_handler_failed:${err.msg()}')
	}
	defer {
		resolved.free()
	}
	raw := resolved.json_stringify()
	e.record_lane_success(lane.id)
	return PluginStreamCallResponse{
		streamed: false
		response: PluginCallResponse{
			ok:     true
			result: raw
		}
	}
}

pub fn (e InProcVjsxExecutor) call_plugin_stream(mut app AppFacade, req PluginCallRequest, on_frame PluginStreamFrameFn) !PluginStreamCallResponse {
	e.remember_app(mut app)
	return e.call_plugin_stream_once(mut app, req, on_frame)
}
