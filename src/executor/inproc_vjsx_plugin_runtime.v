module executor

import json

fn (e InProcVjsxExecutor) call_plugin_once(mut app AppFacade, req PluginCallRequest) !PluginCallResponse {
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
	resolved := host.resolve_value(result) or {
		e.record_lane_error(lane.id, err.msg())
		return error('inproc_vjsx_executor_plugin_handler_failed:${err.msg()}')
	}
	defer {
		resolved.free()
	}
	raw := resolved.json_stringify()
	e.record_lane_success(lane.id)
	return PluginCallResponse{
		ok:     true
		result: raw
	}
}

pub fn (e InProcVjsxExecutor) call_plugin(mut app AppFacade, req PluginCallRequest) !PluginCallResponse {
	e.remember_app(mut app)
	mut last_err := 'inproc_vjsx_executor_plugin_call_failed'
	for attempt in 0 .. inproc_vjsx_dispatch_retry_attempts {
		resp := e.call_plugin_once(mut app, req) or {
			last_err = err.msg()
			if attempt + 1 < inproc_vjsx_dispatch_retry_attempts
				&& InProcVjsxError.should_retry_dispatch(last_err) {
				continue
			}
			return error(last_err)
		}
		return resp
	}
	return error(last_err)
}
