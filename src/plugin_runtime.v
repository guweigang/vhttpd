module main

import plugin
import config

fn build_vjsx_plugin_runtimes(configs map[string]config.PluginConfig) map[string]InProcVjsxExecutor {
	return plugin.build_vjsx_plugin_runtimes(configs)
}

fn (mut app App) close_all_plugins() {
	for _, executor in app.protocols.plugins.vjsx {
		executor.close()
	}
	app.protocols.plugins.vjsx = map[string]InProcVjsxExecutor{}
}

fn (mut app App) call_plugin(req PluginCallRequest) !PluginCallResponse {
	name := req.plugin.trim_space()
	if name == '' {
		return error('plugin_missing_name')
	}
	cfg := app.protocols.plugins.configs[name] or { return error('plugin_not_configured:${name}') }
	if cfg.kind.trim_space().to_lower() !in ['', 'vjsx'] {
		return error('plugin_unsupported_kind:${name}:${cfg.kind}')
	}
	executor := app.protocols.plugins.vjsx[name] or { return error('plugin_runtime_unavailable:${name}') }
	mut facade := app.as_facade()
	return executor.call_plugin(mut facade, req)
}

fn (mut app App) call_plugin_stream(req PluginCallRequest, on_frame PluginStreamFrameFn) !PluginStreamCallResponse {
	name := req.plugin.trim_space()
	if name == '' {
		return error('plugin_missing_name')
	}
	cfg := app.protocols.plugins.configs[name] or { return error('plugin_not_configured:${name}') }
	if cfg.kind.trim_space().to_lower() !in ['', 'vjsx'] {
		return error('plugin_unsupported_kind:${name}:${cfg.kind}')
	}
	executor := app.protocols.plugins.vjsx[name] or { return error('plugin_runtime_unavailable:${name}') }
	mut facade := app.as_facade()
	return executor.call_plugin_stream(mut facade, req, on_frame)
}
