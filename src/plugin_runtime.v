module main

import log

pub struct PluginCallRequest {
pub:
	plugin     string
	capability string
	op         string
	request_id string @[json: 'request_id']
	trace_id   string @[json: 'trace_id']
	payload    string
	metadata   map[string]string
}

pub struct PluginCallResponse {
pub:
	ok     bool
	result string
	error  string
}

pub type PluginStreamFrameFn = fn (string) !bool

pub struct PluginStreamCallResponse {
pub:
	streamed bool
	response PluginCallResponse
}

fn plugin_config_app_entry(cfg PluginConfig) string {
	if cfg.app_entry.trim_space() != '' {
		return cfg.app_entry.trim_space()
	}
	return cfg.entry.trim_space()
}

fn vjsx_plugin_runtime_config(name string, cfg PluginConfig) !VjsxRuntimeFacadeConfig {
	app_entry := plugin_config_app_entry(cfg)
	embedded_cfg := resolve_embedded_host_runtime_config([]string{}, EmbeddedHostRuntimeConfig{
		app_entry:         app_entry
		module_root:       cfg.module_root
		build_root:        cfg.build_root
		signature_root:    cfg.signature_root
		signature_include: cfg.signature_include.clone()
		signature_exclude: cfg.signature_exclude.clone()
		runtime_profile:   cfg.runtime_profile
		lane_count:        cfg.thread_count
		max_requests:      cfg.max_requests
		enable_fs:         cfg.enable_fs
		enable_process:    cfg.enable_process
		enable_network:    cfg.enable_network
	}, EmbeddedHostCliOverrides{}) or {
		return error('plugin_runtime_config_failed:${name}:${err.msg()}')
	}
	return VjsxRuntimeFacadeConfig{
		app_entry:         embedded_cfg.app_entry
		module_root:       embedded_cfg.module_root
		build_root:        embedded_cfg.build_root
		signature_root:    embedded_cfg.signature_root
		signature_include: embedded_cfg.signature_include.clone()
		signature_exclude: embedded_cfg.signature_exclude.clone()
		runtime_profile:   embedded_cfg.runtime_profile
		thread_count:      embedded_cfg.lane_count
		max_requests:      embedded_cfg.max_requests
		enable_fs:         embedded_cfg.enable_fs
		enable_process:    embedded_cfg.enable_process
		enable_network:    embedded_cfg.enable_network
	}
}

fn build_vjsx_plugin_runtimes(configs map[string]PluginConfig) map[string]InProcVjsxExecutor {
	mut runtimes := map[string]InProcVjsxExecutor{}
	for name, cfg in configs {
		if cfg.kind.trim_space().to_lower() !in ['', 'vjsx'] {
			continue
		}
		runtime_cfg := vjsx_plugin_runtime_config(name, cfg) or {
			log.warn('[vhttpd] plugin runtime unavailable name=${name} kind=${cfg.kind} entry=${plugin_config_app_entry(cfg)} error=${err.msg()}')
			continue
		}
		runtimes[name] = new_inproc_vjsx_executor(runtime_cfg)
	}
	return runtimes
}

fn (mut app App) close_all_plugins() {
	for _, executor in app.plugin_vjsx {
		executor.close()
	}
	app.plugin_vjsx = map[string]InProcVjsxExecutor{}
}

fn (mut app App) call_plugin(req PluginCallRequest) !PluginCallResponse {
	name := req.plugin.trim_space()
	if name == '' {
		return error('plugin_missing_name')
	}
	cfg := app.plugin_configs[name] or { return error('plugin_not_configured:${name}') }
	if cfg.kind.trim_space().to_lower() !in ['', 'vjsx'] {
		return error('plugin_unsupported_kind:${name}:${cfg.kind}')
	}
	executor := app.plugin_vjsx[name] or { return error('plugin_runtime_unavailable:${name}') }
	return executor.call_plugin(mut app, req)
}

fn (mut app App) call_plugin_stream(req PluginCallRequest, on_frame PluginStreamFrameFn) !PluginStreamCallResponse {
	name := req.plugin.trim_space()
	if name == '' {
		return error('plugin_missing_name')
	}
	cfg := app.plugin_configs[name] or { return error('plugin_not_configured:${name}') }
	if cfg.kind.trim_space().to_lower() !in ['', 'vjsx'] {
		return error('plugin_unsupported_kind:${name}:${cfg.kind}')
	}
	executor := app.plugin_vjsx[name] or { return error('plugin_runtime_unavailable:${name}') }
	return executor.call_plugin_stream(mut app, req, on_frame)
}
