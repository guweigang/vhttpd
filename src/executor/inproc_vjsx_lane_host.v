module executor

import vjsx

struct VjsxLaneHost {
mut:
	initialized       bool
	startup_completed bool
	dirty             bool
	source_signature  string
	is_module_entry   bool
	build_directory   ?&VjsxBuildDirectory
	app_ref           ?EmbeddedHost
	wakeup_owner      ?&VjsxLaneWakeupOwner
	session           ?&vjsx.RuntimeSession
	module_binding    ?&vjsx.ScriptModule
	request_ctx       InProcVjsxRequestContext
}

fn VjsxLaneHost.empty() VjsxLaneHost {
	return VjsxLaneHost{}
}

fn (mut host VjsxLaneHost) destroy() {
	if owner := host.wakeup_owner { owner.retire() }
	host.wakeup_owner = none
	// Module values depend on the session context: release them first.
	if mut binding := host.module_binding {
		if !binding.is_closed() { binding.close() }
	}
	host.module_binding = none
	if mut session := host.session {
		if !session.is_closed() { session.close() }
	}
	host.session = none
	if mut directory := host.build_directory { directory.release() }
	host.build_directory = none
	host.initialized = false
	host.startup_completed = false
	host.dirty = false
	host.source_signature = ''
	host.is_module_entry = false
	host.app_ref = none
	host.request_ctx = InProcVjsxRequestContext{}
}

// The lane owns both resources. Callers borrow only a live session.
fn (host VjsxLaneHost) session_handle() ?&vjsx.RuntimeSession {
	session := host.session or { return none }
	if session.is_closed() { return none }
	return session
}

fn (host VjsxLaneHost) module_handle() ?&vjsx.ScriptModule {
	binding := host.module_binding or { return none }
	if binding.is_closed() { return none }
	return binding
}

fn (host VjsxLaneHost) context() &vjsx.Context {
	session := host.session_handle() or { panic('inproc_vjsx_executor_session_missing') }
	return session.context()
}

fn (host VjsxLaneHost) resolve_value(val vjsx.Value) !vjsx.Value {
	session := host.session_handle() or { return error('inproc_vjsx_executor_session_missing') }
	return session.resolve_value(val)
}

fn (host VjsxLaneHost) pump_until_idle() {
	session := host.session_handle() or { return }
	session.pump_until_idle()
}

fn (host VjsxLaneHost) call_handler(handler vjsx.Value, args ...vjsx.AnyValue) !vjsx.Value {
	session := host.session_handle() or { return error('inproc_vjsx_executor_session_missing') }
	return session.call(handler, ...args)
}

fn (host VjsxLaneHost) call_handler_resolved(handler vjsx.Value, args ...vjsx.AnyValue) !vjsx.Value {
	result := host.call_handler(handler, ...args)!
	defer {
		result.free()
	}
	return host.resolve_value(result)
}

fn (host VjsxLaneHost) call_global(name string, args ...vjsx.AnyValue) !vjsx.Value {
	session := host.session_handle() or { return error('inproc_vjsx_executor_session_missing') }
	return session.call_global(name, ...args)
}

fn (host VjsxLaneHost) call_global_resolved(name string, args ...vjsx.AnyValue) !vjsx.Value {
	result := host.call_global(name, ...args)!
	defer {
		result.free()
	}
	return host.resolve_value(result)
}

fn (host VjsxLaneHost) call_global_entry(kind string, arg vjsx.Value) !vjsx.Value {
	session := host.session_handle() or { return error('inproc_vjsx_executor_session_missing') }
	ctx := host.context()
	global_name := InProcVjsxEntryResolver.global_handler_name(kind)
	if global_name == '' {
		exports_value := ctx.js_global('__vhttpd_module_exports')
		defer {
			exports_value.free()
		}
		if exports_value.is_object() && exports_value.has(kind) {
			handler := exports_value.get(kind)
			defer {
				handler.free()
			}
			if handler.is_function() {
				return session.call(handler, arg)
			}
		}
		return error('inproc_vjsx_executor_missing_${kind}_handler')
	}
	handler := ctx.js_global(global_name)
	defer {
		handler.free()
	}
	if handler.is_undefined() || !handler.is_function() {
		return error('inproc_vjsx_executor_missing_${kind}_handler')
	}
	return session.call(handler, arg)
}

fn (host VjsxLaneHost) call_module_entry(kind string, arg vjsx.Value) !vjsx.Value {
	module_binding := host.module_handle() or { return error('inproc_vjsx_executor_missing_${kind}_handler') }
	aliases := InProcVjsxEntryResolver.module_aliases(kind)
	if module_binding.has_export('default') {
		default_export := module_binding.default_export() or {
			return error('inproc_vjsx_executor_missing_${kind}_handler')
		}
		if InProcVjsxEntryResolver.module_has_default_function(kind) && default_export.is_function() {
			default_export.free()
			return module_binding.call_export('default', arg)
		}
		if default_export.is_object() {
			for alias in aliases {
				if !default_export.has(alias) {
					continue
				}
				method := default_export.get(alias)
				is_callable := method.is_function()
				method.free()
				if is_callable {
					default_export.free()
					return module_binding.call_default_method(alias, arg)
				}
			}
		}
		default_export.free()
	}
	for alias in aliases {
		if !module_binding.has_export(alias) {
			continue
		}
		export_value := module_binding.get_export(alias) or { continue }
		is_callable := export_value.is_function()
		export_value.free()
		if is_callable {
			return module_binding.call_export(alias, arg)
		}
	}
	return error('inproc_vjsx_executor_missing_${kind}_handler')
}

fn (host VjsxLaneHost) call_entry(kind string, arg vjsx.Value) !vjsx.Value {
	if host.is_module_entry && host.module_handle() != none {
		return host.call_module_entry(kind, arg) or {
			if err.msg() != 'inproc_vjsx_executor_missing_${kind}_handler' {
				return err
			}
			return host.call_global_entry(kind, arg)
		}
	}
	return host.call_global_entry(kind, arg)
}

fn (host VjsxLaneHost) call_entry_resolved(kind string, arg vjsx.Value) !vjsx.Value {
	result := host.call_entry(kind, arg)!
	defer {
		result.free()
	}
	return host.resolve_value(result)
}
