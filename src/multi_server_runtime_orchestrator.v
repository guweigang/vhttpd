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
				listener.runtime_cfg.executor_plan, listener.site_cfg, listener.runtime_cfg.plan,
				listener.runtime_cfg.app_build_cfg)
		}
	}
	share_websocket_listener_apps(mut bindings)
	return bindings
}

fn share_websocket_listener_apps(mut bindings []MultiServerAppBinding) {
	for i in 0 .. bindings.len {
		listener_plan := bindings[i].listener.runtime_cfg.plan.listeners[bindings[i].listener.runtime_cfg.plan_listener_id] or {
			continue
		}
		if listener_plan.protocol.trim_space().to_lower() != 'websocket' {
			continue
		}
		if owner_idx := relay_delivery_owner_binding_index(bindings, bindings[i].listener.runtime_cfg.plan_listener_id) {
			bindings[i].app = bindings[owner_idx].app
		}
	}
}

fn relay_delivery_owner_binding_index(bindings []MultiServerAppBinding, websocket_listener_id string) ?int {
	mut websocket_binding_idx := -1
	for idx, binding in bindings {
		if binding.listener.runtime_cfg.plan_listener_id == websocket_listener_id {
			websocket_binding_idx = idx
			break
		}
	}
	if websocket_binding_idx < 0 {
		return none
	}
	plan := bindings[websocket_binding_idx].listener.runtime_cfg.plan
	for owner_listener_id in plan.relay_delivery_owner_listener_ids(websocket_listener_id) {
		for idx, binding in bindings {
			if binding.listener.runtime_cfg.plan_listener_id == owner_listener_id {
				return idx
			}
		}
	}
	return none
}

fn run_multi_server(args []string, cfg config.VhttpdConfig) ! {
	log.debug('[vhttpd] run_multi_server: resolving multi-server config')
	runtime_cfg := server_lifecycle.resolve_multi_server_runtime_config(args, cfg) or {
		log.error('multi server runtime config resolve failed: ${err}')
		return err
	}
	if runtime_cfg.single_mode {
		log.debug('[vhttpd] run_multi_server: fallback to single mode')
		run_single_server(args, cfg)!
		return
	}
	if runtime_cfg.listeners.len == 0 {
		msg := 'multi server runtime start failed: no listeners configured'
		log.error(msg)
		return error(msg)
	}
	for binding in runtime_cfg.listeners {
		preflight_server_bind(binding.runtime_cfg) or {
			log.error('[vhttpd] ${err.msg()}')
			return err
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
