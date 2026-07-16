module executor

import json
import log

fn (e InProcVjsxExecutor) build_startup_runtime_payload(lane VjsxExecutionLane, kind string) string {
	config := e.facade_snapshot().config
	request_id := InProcVjsxStartupCodec.request_id(kind, lane.id)
	path := InProcVjsxStartupCodec.path(kind)
	return json.encode(InProcVjsxRuntimeMeta{
		provider:                 e.provider()
		executor:                 e.kind()
		dispatch_kind:            kind
		lane_id:                  lane.id
		request_id:               request_id
		trace_id:                 request_id
		app_entry:                config.app_entry
		module_root:              config.module_root
		build_root:               config.build_root
		runtime_profile:          config.runtime_profile
		thread_count:             config.thread_count
		enable_fs:                config.enable_fs
		enable_process:           config.enable_process
		enable_network:           config.enable_network
		request_scheme:           ''
		request_host:             ''
		request_port:             ''
		request_target:           path
		request_protocol_version: ''
		request_remote_addr:      ''
		request_server:           map[string]string{}
		method:                   InProcVjsxStartupCodec.method(kind)
		path:                     path
	})
}

fn (e InProcVjsxExecutor) execute_startup_hook(mut app AppFacade, idx int, lane VjsxExecutionLane, kind string) ! {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	log.debug('[vhttpd] startup_hook begin lane=${lane.id} idx=${idx} kind=${kind}')
	e.ensure_lane_host(idx)!
	mut state := e.state
	state.mu.@lock()
	host := state.hosts[idx]
	state.mu.unlock()
	js_ctx_host := host.context()
	hook_global_name := if kind == 'app_startup' {
		'__vhttpd_app_startup_handle'
	} else {
		'__vhttpd_startup_handle'
	}
	hook_probe := js_ctx_host.js_global(hook_global_name)
	if hook_probe.is_undefined() || !hook_probe.is_function() {
		log.debug('[vhttpd] startup_hook skip lane=${lane.id} idx=${idx} kind=${kind} reason=missing_handler')
		hook_probe.free()
		return
	}
	hook_probe.free()
	request_id := InProcVjsxStartupCodec.request_id(kind, lane.id)
	e.activate_lane_request_context(idx, mut app, lane.id, HttpLogicDispatchRequest{
		method:     InProcVjsxStartupCodec.method(kind)
		path:       InProcVjsxStartupCodec.path(kind)
		trace_id:   request_id
		request_id: request_id
	})
	defer {
		e.clear_lane_request_context(idx)
	}
	runtime_obj := js_ctx_host.json_parse(e.build_startup_runtime_payload(lane, kind))
	defer {
		runtime_obj.free()
	}
	create_runtime_fn := js_ctx_host.js_global('__vhttpd_create_runtime')
	defer {
		create_runtime_fn.free()
	}
	log.debug('[vhttpd] startup_hook runtime_create lane=${lane.id} idx=${idx} kind=${kind}')
	mut js_runtime := host.call_handler(create_runtime_fn, runtime_obj) or {
		return error('inproc_vjsx_executor_${kind}_runtime_create_failed:${err.msg()}')
	}
	defer {
		js_runtime.free()
	}
	mut result := if host.is_module_entry && !isnil(host.module_binding) {
		host.call_entry(kind, js_runtime) or {
			if err.msg() == 'inproc_vjsx_executor_missing_${kind}_handler' {
				return
			}
			return error('inproc_vjsx_executor_${kind}_failed:${err.msg()}')
		}
	} else {
		hook := js_ctx_host.js_global(hook_global_name)
		defer {
			hook.free()
		}
		if hook.is_undefined() || !hook.is_function() {
			return
		}
		host.call_handler_resolved(hook, js_runtime) or {
			return error('inproc_vjsx_executor_${kind}_failed:${err.msg()}')
		}
	}
	defer {
		result.free()
	}
	log.debug('[vhttpd] startup_hook handler_ok lane=${lane.id} idx=${idx} kind=${kind} promise=${result.instanceof('Promise')}')
	normalize_fn := js_ctx_host.js_global('__vhttpd_normalize_startup_result')
	defer {
		normalize_fn.free()
	}
	resolved := host.resolve_value(result) or {
		return error('inproc_vjsx_executor_${kind}_failed:${err.msg()}')
	}
	defer {
		resolved.free()
	}
	mut normalized := host.call_handler(normalize_fn, resolved) or {
		return error('inproc_vjsx_executor_${kind}_normalize_failed:${err.msg()}')
	}
	defer {
		normalized.free()
	}
	commands := InProcVjsxStartupCodec.commands_from_js_value(normalized)
	if commands.len == 0 {
		return
	}
	dispatch_ctx := DispatchContext{
		metadata: {
			'dispatch_kind': kind
			'lane_id':       lane.id
		}
		event:    kind
	}
	command_error := app.run_command_envelopes(request_id, dispatch_ctx, commands)
	if command_error != '' {
		return error('inproc_vjsx_executor_${kind}_command_failed:${command_error}')
	}
	log.debug('[vhttpd] startup_hook done lane=${lane.id} idx=${idx} kind=${kind} commands=${commands.len}')
}
