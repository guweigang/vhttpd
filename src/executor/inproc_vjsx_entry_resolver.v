module executor

import vjsx

struct InProcVjsxEntryResolver {}

fn InProcVjsxEntryResolver.module_aliases(kind string) []string {
	return match kind {
		'http' {
			['handle', 'http', 'handleHttp', 'handle_http']
		}
		'websocket' {
			['websocket', 'handleWebSocket', 'handle_websocket']
		}
		'websocket_affinity' {
			['websocket_affinity', 'websocketAffinity', 'getWebSocketAffinity',
				'get_websocket_affinity']
		}
		'websocket_actor' {
			['websocket_actor', 'websocketActor', 'getWebSocketActor', 'get_websocket_actor']
		}
		'websocket_upstream' {
			['websocket_upstream', 'websocketUpstream', 'handleWebSocketUpstream',
				'handle_websocket_upstream']
		}
		'plugin' {
			['plugin', 'handlePlugin', 'handle_plugin']
		}
		'openai' {
			['openai', 'openaiPlugin', 'handleOpenAI', 'handleOpenai', 'handle_openai']
		}
		'startup' {
			['startup', 'lane_startup', 'laneStartup']
		}
		'app_startup' {
			['app_startup', 'appStartup']
		}
		'snapshot' {
			['snapshot', 'lane_snapshot', 'laneSnapshot']
		}
		else {
			if kind.trim_space() != '' {
				[kind.trim_space()]
			} else {
				[]string{}
			}
		}
	}
}

fn InProcVjsxEntryResolver.module_has_default_function(kind string) bool {
	return kind in ['http', 'websocket']
}

fn InProcVjsxEntryResolver.global_handler_name(kind string) string {
	return match kind {
		'http' { '__vhttpd_handle' }
		'websocket' { '__vhttpd_websocket_handle' }
		'websocket_affinity' { '__vhttpd_websocket_affinity_handle' }
		'websocket_actor' { '__vhttpd_websocket_actor_handle' }
		'websocket_upstream' { '__vhttpd_websocket_upstream_handle' }
		'plugin' { '__vhttpd_plugin_handle' }
		'openai' { '__vhttpd_openai_handle' }
		'startup' { '__vhttpd_startup_handle' }
		'app_startup' { '__vhttpd_app_startup_handle' }
		'snapshot' { '__vhttpd_snapshot_handle' }
		else { '' }
	}
}

fn InProcVjsxEntryResolver.global_has_callable(ctx vjsx.Context, kind string) bool {
	global_name := InProcVjsxEntryResolver.global_handler_name(kind)
	if global_name == '' {
		return false
	}
	handler := ctx.js_global(global_name)
	defer {
		handler.free()
	}
	return !handler.is_undefined() && handler.is_function()
}

fn InProcVjsxEntryResolver.module_has_callable(module_binding &vjsx.ScriptModule, kind string) bool {
	aliases := InProcVjsxEntryResolver.module_aliases(kind)
	if module_binding.has_export('default') {
		default_export := module_binding.default_export() or { return false }
		defer {
			default_export.free()
		}
		if InProcVjsxEntryResolver.module_has_default_function(kind) && default_export.is_function() {
			return true
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
					return true
				}
			}
		}
	}
	for alias in aliases {
		if !module_binding.has_export(alias) {
			continue
		}
		export_value := module_binding.get_export(alias) or { continue }
		is_callable := export_value.is_function()
		export_value.free()
		if is_callable {
			return true
		}
	}
	return false
}
