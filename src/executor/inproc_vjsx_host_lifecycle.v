module executor

import log
import os
import vjsx
import vjsx.runtimejs

pub fn (e InProcVjsxExecutor) ensure_lane_host(idx int) ! {
	mut state := e.state
	state.mu.@lock()
	if state.stopping {
		state.mu.unlock()
		return error('inproc_vjsx_executor_closed')
	}
	state.host_builders++
	state.mu.unlock()
	defer {
		state.mu.@lock()
		state.host_builders--
		state.mu.unlock()
	}
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
	if host.initialized && !host.dirty && host.session_handle() != none
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
	mut directory := VjsxBuildDirectory.reserve(config.lane_temp_root(idx, source_signature))!
	// Builders may recreate their output directory; retain an untouched parent.
	temp_root := directory.output_path()
	mut owned_by_lane := false
	defer { if !owned_by_lane { directory.release() } }
	mut session := InProcVjsxRuntimeSessionFactory.new(config)!
	wake_owner := state.new_lane_wakeup_owner(lane_id) or {
		if !session.is_closed() { session.close() }
		return err
	}
	e.attach_task_session(lane_id, session)
	defer {
		if !owned_by_lane {
			wake_owner.retire()
			state.mu.@lock()
			state.detach_task_session_locked(lane_id)
			state.mu.unlock()
			if !session.is_closed() { session.close() }
		}
	}
	session.set_diagnostic_handler(inproc_vjsx_runtime_session_diagnostic_handler)
	session.configure_event_loop(vjsx.RuntimeSessionEventLoopConfig{
		session_id:     lane_id
		wake_fn:        fn [wake_owner] (req vjsx.RuntimeSessionWakeRequest) {
			wake_owner.schedule(req.wake_at_ms, req.generation)
		}
		cancel_wake_fn: fn [wake_owner] (req vjsx.RuntimeSessionWakeCancelRequest) {
			wake_owner.cancel(req.generation)
		}
		async_ready_fn: fn [wake_owner] (_req vjsx.RuntimeHostAsyncReadyRequest) {
			wake_owner.schedule_async()
		}
	})
	log.debug('[vhttpd] ensure_lane_host runtime ready lane=${lane_id} idx=${idx} module=${as_module} temp_root=${temp_root}')
	mut ctx := session.context()
	InProcVjsxHostApi.install_http_facade(mut ctx)!
	InProcVjsxHostApi.install(mut ctx, mut state, idx)
	InProcVjsxRuntimeProfileLog.write(lane_id, idx, config.runtime_profile, ctx)
	mut module_binding_ptr := ?&vjsx.ScriptModule(none)
	mut has_http_handler := false
	mut has_websocket_handler := false
	mut has_upstream_handler := false
	mut has_plugin_handler := false
	defer { release_inproc_vjsx_compiler_memory() }
	prepared_entry := e.prepare_inproc_vjsx_module(config, temp_root, lane_id, session, as_module) or {
		return error('inproc_vjsx_executor_bootstrap_failed:${err.msg()}')
	}
	if as_module {
		log.debug('[vhttpd] ensure_lane_host importing module lane=${lane_id} idx=${idx}')
		js_flag_eval :=
			ctx.eval('var __vhttpd_enable_item_render_streams__ = ${config.enable_item_render_streams};')!
		defer {
			js_flag_eval.free()
		}
		module_binding_value := VjsxHostLoader.import_prepared_entry(mut session, prepared_entry) or {
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
				return error('inproc_vjsx_executor_module_namespace_failed:${err.msg()}')
			}
			defer {
				entry_exports.free()
			}
			mut bound := session.call(bind_handlers, entry_exports) or {
				mut cleanup_binding := module_binding_value
				cleanup_binding.close()
				return error('inproc_vjsx_executor_export_bind_failed:${err.msg()}')
			}
			defer {
				bound.free()
			}
		}
		// The lane outlives this function; allocate its module binding on the heap.
		module_binding_ptr = &vjsx.ScriptModule{
			...module_binding_value
		}
	} else {
		log.debug('[vhttpd] ensure_lane_host loading script entry lane=${lane_id} idx=${idx}')
		mut entry_exports := VjsxHostLoader.load_prepared_script(mut ctx, config, prepared_entry) or {
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
		build_directory:   directory
		wakeup_owner:      wake_owner
		session:           session
		module_binding:    module_binding_ptr
	}
	mut published_wake_owner := unsafe { wake_owner }
	published_wake_owner.published = true
	owned_by_lane = true
	state.lanes[idx].healthy = true
	state.lanes[idx].dirty = false
	log.debug('[vhttpd] ensure_lane_host ready lane=${lane_id} idx=${idx} http=${has_http_handler} websocket=${has_websocket_handler} upstream=${has_upstream_handler} plugin=${has_plugin_handler}')
}

// Module scanning/transpilation needs the full TypeScript compiler. Keep it
// outside the long-lived execution context, which only imports prepared JS.
fn (e InProcVjsxExecutor) prepare_inproc_vjsx_module(config VjsxRuntimeFacadeConfig, temp_root string, lane_id string, execution &vjsx.RuntimeSession, as_module bool) !string {
	mut compiler := InProcVjsxRuntimeSessionFactory.new_compiler(config)
	e.attach_task_session(lane_id, compiler)
	defer {
		// Cancellation must follow the active runtime, including during bootstrap.
		e.attach_task_session(lane_id, execution)
		compiler.close()
	}
	entry := os.real_path(config.app_entry)
	if !as_module {
		if !runtimejs.is_commonjs_module(compiler.context(), entry)! { return '' }
	}
	return runtimejs.build_runtime_module_entry(compiler.context(), entry, true, temp_root)
}
