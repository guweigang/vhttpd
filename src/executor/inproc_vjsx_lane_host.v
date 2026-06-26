module executor

import os
import vjsx

struct VjsxLaneHost {
mut:
	initialized       bool
	startup_completed bool
	dirty             bool
	source_signature  string
	is_module_entry   bool
	temp_root         string
	app_ref           AppFacade            = NoOpAppFacade{}
	session           &vjsx.RuntimeSession = unsafe { nil }
	module_binding    &vjsx.ScriptModule   = unsafe { nil }
	request_ctx       InProcVjsxRequestContext
}

fn VjsxLaneHost.empty() VjsxLaneHost {
	return VjsxLaneHost{
		session:        unsafe { nil }
		module_binding: unsafe { nil }
	}
}

fn (mut host VjsxLaneHost) destroy() {
	if host.is_module_entry && !isnil(host.module_binding) && !host.module_binding.is_closed() {
		host.module_binding.close()
		host.module_binding = unsafe { nil }
	}
	if host.initialized && !isnil(host.session) && !host.session.is_closed() {
		host.session.close()
		host.session = unsafe { nil }
	}
	if host.temp_root.trim_space() != '' {
		os.rmdir_all(host.temp_root) or {} // safe to ignore: temp dir may already be removed
	}
	host.initialized = false
	host.startup_completed = false
	host.dirty = false
	host.source_signature = ''
	host.is_module_entry = false
	host.temp_root = ''
	host.app_ref = unsafe { nil }
	host.request_ctx = InProcVjsxRequestContext{}
}

// VjsxLaneHost facade: thin host-side wrapper around the lane session. Keep
// executor call sites on host methods rather than long free-function chains.
fn (host VjsxLaneHost) context() &vjsx.Context {
	if isnil(host.session) {
		panic('inproc_vjsx_executor_session_missing')
	}
	return host.session.context()
}

fn (host VjsxLaneHost) resolve_value(val vjsx.Value) !vjsx.Value {
	if isnil(host.session) || host.session.is_closed() {
		return error('inproc_vjsx_executor_session_missing')
	}
	return host.session.resolve_value(val)
}

fn (host VjsxLaneHost) pump_until_idle() {
	if isnil(host.session) || host.session.is_closed() {
		return
	}
	host.session.pump_until_idle()
}

fn (host VjsxLaneHost) call_handler(handler vjsx.Value, args ...vjsx.AnyValue) !vjsx.Value {
	if isnil(host.session) || host.session.is_closed() {
		return error('inproc_vjsx_executor_session_missing')
	}
	return host.session.call(handler, ...args)
}

fn (host VjsxLaneHost) call_handler_resolved(handler vjsx.Value, args ...vjsx.AnyValue) !vjsx.Value {
	result := host.call_handler(handler, ...args)!
	defer {
		result.free()
	}
	return host.resolve_value(result)
}

fn (host VjsxLaneHost) call_global(name string, args ...vjsx.AnyValue) !vjsx.Value {
	if isnil(host.session) || host.session.is_closed() {
		return error('inproc_vjsx_executor_session_missing')
	}
	return host.session.call_global(name, ...args)
}

fn (host VjsxLaneHost) call_global_resolved(name string, args ...vjsx.AnyValue) !vjsx.Value {
	result := host.call_global(name, ...args)!
	defer {
		result.free()
	}
	return host.resolve_value(result)
}

fn (host VjsxLaneHost) call_global_entry(kind string, arg vjsx.Value) !vjsx.Value {
	if isnil(host.session) || host.session.is_closed() {
		return error('inproc_vjsx_executor_session_missing')
	}
	ctx := host.context()
	global_name := InProcVjsxEntryResolver.global_handler_name(kind)
	if global_name == '' {
		return error('inproc_vjsx_executor_missing_${kind}_handler')
	}
	handler := ctx.js_global(global_name)
	defer {
		handler.free()
	}
	if handler.is_undefined() || !handler.is_function() {
		return error('inproc_vjsx_executor_missing_${kind}_handler')
	}
	return host.session.call(handler, arg)
}

fn (host VjsxLaneHost) call_module_entry(kind string, arg vjsx.Value) !vjsx.Value {
	if isnil(host.module_binding) {
		return error('inproc_vjsx_executor_missing_${kind}_handler')
	}
	module_binding := host.module_binding
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
	if host.is_module_entry && !isnil(host.module_binding) {
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
