module main

import config
import server_lifecycle
import log
import runtime_plan

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
	for relay_id in relay_ids_for_websocket_listener(bindings, websocket_listener_id) {
		for idx, binding in bindings {
			listener_plan := binding.listener.runtime_cfg.plan.listeners[binding.listener.runtime_cfg.plan_listener_id] or {
				continue
			}
			if listener_plan.protocol.trim_space().to_lower() == 'websocket' {
				continue
			}
			if listener_has_relay_delivery_target(binding.listener.runtime_cfg.plan,
				binding.listener.runtime_cfg.plan_listener_id, relay_id) {
				return idx
			}
		}
	}
	return none
}

fn relay_ids_for_websocket_listener(bindings []MultiServerAppBinding, websocket_listener_id string) []string {
	mut ids := []string{}
	for binding in bindings {
		for relay_id, relay_plan in binding.listener.runtime_cfg.plan.relays {
			ingress := relay_plan.ingress or { continue }
			if ingress.domain == .listener && ingress.id == websocket_listener_id && relay_id !in ids {
				ids << relay_id
			}
		}
	}
	ids.sort()
	return ids
}

fn listener_has_relay_delivery_target(plan runtime_plan.RuntimePlan, listener_id string, relay_id string) bool {
	target := 'relay:${relay_id}'
	for pipeline in plan.listener_pipelines(listener_id) {
		if pipeline.egress.domain != .adapter {
			continue
		}
		adapter := plan.adapters[pipeline.egress.id] or { continue }
		if adapter.kind == 'relay-delivery' && adapter.options.strings['target'] == target {
			return true
		}
	}
	return false
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
