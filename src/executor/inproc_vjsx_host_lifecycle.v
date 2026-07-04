module executor

import log
import os
import vjsx
import vjsx.runtimejs

pub fn (e InProcVjsxExecutor) ensure_lane_host(idx int) ! {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	config := e.facade_snapshot().config
	source_signature := e.current_source_signature()
	mut needs_reset := false
	lane_id := if idx >= 0 && idx < state.lanes.len { state.lanes[idx].id } else { '' }
	state.mu.@lock()
	if idx < 0 || idx >= state.hosts.len || idx >= state.lanes.len {
		state.mu.unlock()
		return error('inproc_vjsx_executor_invalid_lane')
	}
	host := state.hosts[idx]
	if host.initialized && !host.dirty && !isnil(host.session) && !host.session.is_closed()
		&& host.source_signature == source_signature {
		state.mu.unlock()
		return
	}
	needs_reset = host.initialized
	state.mu.unlock()
	log.debug('[vhttpd] ensure_lane_host start lane=${lane_id} idx=${idx} needs_reset=${needs_reset} app_entry=${config.app_entry}')
	if needs_reset {
		log.debug('[vhttpd] ensure_lane_host resetting lane=${lane_id} idx=${idx}')
		e.reset_lane_host(idx)
	}

	as_module := VjsxHostLoader.entry_runs_as_module(config.app_entry)!
	temp_root := config.lane_temp_root(idx, source_signature)
	mut session := InProcVjsxRuntimeSessionFactory.new(config)!
	session.set_diagnostic_handler(inproc_vjsx_runtime_session_diagnostic_handler)
	session.configure_event_loop(vjsx.RuntimeSessionEventLoopConfig{
		session_id:     lane_id
		wake_fn:        fn [mut state, lane_id] (req vjsx.RuntimeSessionWakeRequest) {
			state.schedule_lane_wakeup(lane_id, req.wake_at_ms, req.generation)
		}
		cancel_wake_fn: fn [mut state, lane_id] (req vjsx.RuntimeSessionWakeCancelRequest) {
			state.cancel_lane_wakeup(lane_id, req.generation)
		}
	})
	log.debug('[vhttpd] ensure_lane_host runtime ready lane=${lane_id} idx=${idx} module=${as_module} temp_root=${temp_root}')
	mut ctx := session.context()
	InProcVjsxHostApi.install_http_facade(mut ctx)!
	InProcVjsxHostApi.install(mut ctx, mut state, idx)
	InProcVjsxRuntimeProfileLog.write(lane_id, idx, config.runtime_profile, ctx)
	mut module_binding_ptr := &vjsx.ScriptModule(unsafe { nil })
	mut has_http_handler := false
	mut has_websocket_handler := false
	mut has_upstream_handler := false
	mut has_plugin_handler := false
	if as_module {
		if vjsx.is_typescript_file(config.app_entry)
			|| vjsx.is_runtime_module_file(config.app_entry) {
			runtimejs.install_typescript_runtime(ctx)!
		}
		log.debug('[vhttpd] ensure_lane_host importing module lane=${lane_id} idx=${idx}')
		js_flag_eval :=
			ctx.eval('var __vhttpd_enable_item_render_streams__ = ${config.enable_item_render_streams};')!
		defer {
			js_flag_eval.free()
		}
		module_entry_path := runtimejs.build_runtime_module_entry(ctx, config.app_entry, true,
			temp_root) or {
			session.close()
			os.rmdir_all(temp_root) or {} // safe to ignore: temp dir may already be removed
			return error('inproc_vjsx_executor_bootstrap_failed:${err.msg()}')
		}
		module_binding_value := session.import_module(module_entry_path) or {
			session.close()
			os.rmdir_all(temp_root) or {} // safe to ignore: temp dir may already be removed
			return error('inproc_vjsx_executor_module_import_failed:${err.msg()}')
		}
		has_http_handler =
			InProcVjsxEntryResolver.module_has_callable(&module_binding_value, 'http')
			|| InProcVjsxEntryResolver.global_has_callable(ctx, 'http')
		has_websocket_handler =
			InProcVjsxEntryResolver.module_has_callable(&module_binding_value, 'websocket')
			|| InProcVjsxEntryResolver.global_has_callable(ctx, 'websocket')
		has_upstream_handler =
			InProcVjsxEntryResolver.module_has_callable(&module_binding_value, 'websocket_upstream')
			|| InProcVjsxEntryResolver.global_has_callable(ctx, 'websocket_upstream')
		has_plugin_handler =
			InProcVjsxEntryResolver.module_has_callable(&module_binding_value, 'plugin')
			|| InProcVjsxEntryResolver.module_has_callable(&module_binding_value, 'openai')
			|| InProcVjsxEntryResolver.global_has_callable(ctx, 'plugin')
			|| InProcVjsxEntryResolver.global_has_callable(ctx, 'openai')
		bind_handlers := ctx.js_global('__vhttpd_bind_handlers')
		defer {
			bind_handlers.free()
		}
		if !bind_handlers.is_undefined() && bind_handlers.is_function() {
			entry_exports := module_binding_value.namespace() or {
				mut cleanup_binding := module_binding_value
				cleanup_binding.close()
				session.close()
				os.rmdir_all(temp_root) or {} // safe to ignore: temp dir may already be removed
				return error('inproc_vjsx_executor_module_namespace_failed:${err.msg()}')
			}
			defer {
				entry_exports.free()
			}
			mut bound := session.call(bind_handlers, entry_exports) or {
				mut cleanup_binding := module_binding_value
				cleanup_binding.close()
				session.close()
				os.rmdir_all(temp_root) or {} // safe to ignore: temp dir may already be removed
				return error('inproc_vjsx_executor_export_bind_failed:${err.msg()}')
			}
			defer {
				bound.free()
			}
		}
		mut module_binding := module_binding_value
		module_binding_ptr = &module_binding
	} else {
		log.debug('[vhttpd] ensure_lane_host loading script entry lane=${lane_id} idx=${idx}')
		mut entry_exports := VjsxHostLoader.load_entry(mut ctx, config, idx, source_signature,
			false) or {
			session.close()
			os.rmdir_all(temp_root) or {} // safe to ignore: temp dir may already be removed
			return error('inproc_vjsx_executor_bootstrap_failed:${err.msg()}')
		}
		defer {
			entry_exports.free()
		}
		bind_handler := ctx.js_global('__vhttpd_bind_handler')
		defer {
			bind_handler.free()
		}
		bind_handlers := ctx.js_global('__vhttpd_bind_handlers')
		defer {
			bind_handlers.free()
		}
		if !bind_handlers.is_undefined() && bind_handlers.is_function() {
			mut bound := session.call(bind_handlers, entry_exports) or {
				session.close()
				os.rmdir_all(temp_root) or {} // safe to ignore: temp dir may already be removed
				return error('inproc_vjsx_executor_export_bind_failed:${err.msg()}')
			}
			defer {
				bound.free()
			}
		}
		http_handler := ctx.js_global('__vhttpd_handle')
		websocket_handler := ctx.js_global('__vhttpd_websocket_handle')
		upstream_handler := ctx.js_global('__vhttpd_websocket_upstream_handle')
		plugin_handler := ctx.js_global('__vhttpd_plugin_handle')
		openai_handler := ctx.js_global('__vhttpd_openai_handle')
		has_http_handler = !http_handler.is_undefined() && http_handler.is_function()
		has_websocket_handler = !websocket_handler.is_undefined() && websocket_handler.is_function()
		has_upstream_handler = !upstream_handler.is_undefined() && upstream_handler.is_function()
		has_plugin_handler = (!plugin_handler.is_undefined() && plugin_handler.is_function())
			|| (!openai_handler.is_undefined() && openai_handler.is_function())
		http_handler.free()
		websocket_handler.free()
		upstream_handler.free()
		plugin_handler.free()
		openai_handler.free()
		if !has_http_handler && !has_websocket_handler && !has_upstream_handler
			&& !has_plugin_handler {
			session.close()
			os.rmdir_all(temp_root) or {} // safe to ignore: temp dir may already be removed
			return error('inproc_vjsx_executor_missing_handler')
		}
	}

	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	state.hosts[idx] = VjsxLaneHost{
		initialized:       true
		startup_completed: false
		dirty:             false
		source_signature:  source_signature
		is_module_entry:   as_module
		temp_root:         temp_root
		session:           session
		module_binding:    module_binding_ptr
	}
	state.lanes[idx].healthy = true
	state.lanes[idx].dirty = false
	log.debug('[vhttpd] ensure_lane_host ready lane=${lane_id} idx=${idx} http=${has_http_handler} websocket=${has_websocket_handler} upstream=${has_upstream_handler} plugin=${has_plugin_handler}')
}
