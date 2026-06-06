module server_lifecycle

import config

pub struct ListenerRuntimeBinding {
pub:
	id          string
	site_id     string
	site_cfg    config.VhttpdConfig
	runtime_cfg ServerRuntimeConfig
}

pub struct MultiServerRuntimeConfig {
pub:
	single_mode bool
	listeners   []ListenerRuntimeBinding
}

pub fn resolve_multi_server_runtime_config(args []string, cfg config.VhttpdConfig) !MultiServerRuntimeConfig {
	if !cfg.uses_multi_listener() {
		return MultiServerRuntimeConfig{
			single_mode: true
			listeners:   [
				ListenerRuntimeBinding{
					id:          'default'
					site_id:     'default'
					site_cfg:    cfg
					runtime_cfg: ServerRuntimeConfig.resolve(args, cfg)!
				},
			]
		}
	}
	if cfg.listeners.len == 0 {
		if cfg.sites.len == 0 {
			return error('multi_listener_missing_sites')
		}
	}
	listeners := cfg.resolve_multi_listeners()!
	mut listener_ids := listeners.keys()
	listener_ids.sort()
	admin_owner_listener_id := if cfg.admin.port > 0 && listener_ids.len > 0 {
		listener_ids[0]
	} else {
		''
	}
	mut used_bindings := map[string]bool{}
	mut bindings := []ListenerRuntimeBinding{cap: listener_ids.len}
	for listener_id in listener_ids {
		listener_cfg := listeners[listener_id]
		site_id := listener_cfg.site.trim_space()
		if site_id == '' {
			return error('multi_listener_missing_site:${listener_id}')
		}
		if site_id !in cfg.sites {
			return error('multi_listener_unknown_site:${listener_id}:${site_id}')
		}
		binding_key := '${listener_cfg.host}:${listener_cfg.port}'
		if binding_key in used_bindings {
			return error('multi_listener_duplicate_bind:${binding_key}')
		}
		used_bindings[binding_key] = true
		mut site_runtime_cfg := cfg.with_site(cfg.sites[site_id])
		if site_runtime_cfg.config_path != '' {
			config.resolve_config_variables(mut site_runtime_cfg, site_runtime_cfg.config_path)!
		}
		admin_enabled_override := listener_id == admin_owner_listener_id
		runtime_cfg := ServerRuntimeConfig.resolve_for_target(args, site_runtime_cfg, listener_id,
			site_id, listener_cfg.host, listener_cfg.port, admin_enabled_override)!
		bindings << ListenerRuntimeBinding{
			id:          listener_id
			site_id:     site_id
			site_cfg:    site_runtime_cfg
			runtime_cfg: runtime_cfg
		}
	}
	return MultiServerRuntimeConfig{
		single_mode: false
		listeners:   bindings
	}
}
