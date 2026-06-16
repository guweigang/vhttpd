module main

import config
import server_lifecycle
import log

struct MultiServerAppBinding {
mut:
	listener server_lifecycle.ListenerRuntimeBinding
	app      &App = unsafe { nil }
}

fn build_multi_server_apps(runtime_cfg server_lifecycle.MultiServerRuntimeConfig) []MultiServerAppBinding {
	mut bindings := []MultiServerAppBinding{cap: runtime_cfg.listeners.len}
	for listener in runtime_cfg.listeners {
		bindings << MultiServerAppBinding{
			listener: listener
			app:      build_app_runtime(listener.runtime_cfg.provider_settings,
				listener.runtime_cfg.executor_plan, listener.site_cfg,
				listener.runtime_cfg.app_build_cfg)
		}
	}
	return bindings
}

fn run_multi_server(args []string, cfg config.VhttpdConfig) {
	log.debug('[vhttpd] run_multi_server: resolving multi-server config')
	runtime_cfg := server_lifecycle.resolve_multi_server_runtime_config(args, cfg) or {
		log.error('multi server runtime config resolve failed: ${err}')
		return
	}
	if runtime_cfg.single_mode {
		log.debug('[vhttpd] run_multi_server: fallback to single mode')
		run_single_server(args, cfg)
		return
	}
	if runtime_cfg.listeners.len == 0 {
		log.error('multi server runtime start failed: no listeners configured')
		return
	}
	for binding in runtime_cfg.listeners {
		preflight_server_bind(binding.runtime_cfg) or {
			log.error('[vhttpd] ${err.msg()}')
			return
		}
	}
	mut apps := build_multi_server_apps(runtime_cfg)
	log.debug('[vhttpd] run_multi_server: apps built count=${apps.len}')
	for i in 0 .. apps.len {
		register_active_runtime(apps[i].app, apps[i].listener.runtime_cfg)
	}
	defer {
		if !active_runtime_is_shutting_down() {
			for mut binding in apps {
				shutdown_app_runtime(mut binding.app, binding.listener.runtime_cfg)
			}
		}
	}
	for mut binding in apps {
		log.debug('[vhttpd] run_multi_server: starting app site=${binding.listener.site_id} listener=${binding.listener.id}')
		start_server_runtime(mut binding.app, binding.listener.runtime_cfg)
	}
	for i in 0 .. apps.len - 1 {
		mut app_ref := apps[i].app
		spawn serve_server_runtime(mut app_ref, apps[i].listener.runtime_cfg)
	}
	mut last_app := apps[apps.len - 1].app
	serve_server_runtime(mut last_app, apps[apps.len - 1].listener.runtime_cfg)
}
