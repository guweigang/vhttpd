module server_lifecycle

import config
import runtime_plan
import executor

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
	plan := config.load_runtime_plan_or_compile_config(args, cfg)!
	if !cfg.uses_multi_listener() {
		if plan.listeners.len > 1 {
			return resolve_plan_multi_server_runtime_config(args, cfg, plan)!
		}
		site_id := cfg.default_site_id()
		return MultiServerRuntimeConfig{
			single_mode: true
			listeners:   [
				ListenerRuntimeBinding{
					id:          'default'
					site_id:     site_id
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
	admin_port := config.CliArgs.int_or(args, '--admin-port', cfg.admin.port)
	requested_admin_owner := if admin_port > 0 && listener_ids.len > 0 {
		listener_ids[0]
	} else {
		''
	}
	admin_owner_listener_id := plan.listener_app_owner_id(requested_admin_owner, listener_ids)
	mut used_bindings := map[string]bool{}
	mut targets := []MultiServerResolveTarget{cap: listener_ids.len}
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
		ssl_cfg := if listener_cfg.ssl.cert.trim_space() != ''
			|| listener_cfg.ssl.cert_key.trim_space() != '' || listener_cfg.ssl.enabled {
			listener_cfg.ssl
		} else {
			site_runtime_cfg.server.ssl
		}
		targets << MultiServerResolveTarget{
			id:            listener_id
			site_id:       site_id
			cfg:           site_runtime_cfg
			host:          listener_cfg.host
			port:          listener_cfg.port
			ssl:           ssl_cfg
			admin_enabled: admin_enabled_override
		}
	}
	return MultiServerRuntimeConfig{
		single_mode: false
		listeners:   resolve_multi_server_targets(args, plan, targets)!
	}
}

fn resolve_plan_multi_server_runtime_config(args []string, cfg config.VhttpdConfig, plan runtime_plan.RuntimePlan) !MultiServerRuntimeConfig {
	mut listener_ids := plan.listeners.keys()
	listener_ids.sort()
	requested_admin_owner := if control_listener := plan.control.listener {
		if control_listener.domain == .listener {
			control_listener.id
		} else {
			''
		}
	} else if listener_ids.len > 0 {
		listener_ids[0]
	} else {
		''
	}
	admin_owner_listener_id := plan.listener_app_owner_id(requested_admin_owner, listener_ids)
	mut used_bindings := map[string]bool{}
	mut targets := []MultiServerResolveTarget{cap: listener_ids.len}
	for listener_id in listener_ids {
		listener := plan.listeners[listener_id]
		host := if listener.host.trim_space() == '' { '127.0.0.1' } else { listener.host }
		if listener.port <= 0 {
			return error('runtime_plan_listener_missing_port:${listener_id}')
		}
		binding_key := '${host}:${listener.port}'
		if binding_key in used_bindings {
			return error('multi_listener_duplicate_bind:${binding_key}')
		}
		used_bindings[binding_key] = true
		site_id := listener_id
		admin_enabled_override := listener_id == admin_owner_listener_id
		ssl_cfg := server_ssl_config_from_plan_listener(listener, cfg.server.ssl)
		targets << MultiServerResolveTarget{
			id:            listener_id
			site_id:       site_id
			cfg:           cfg
			host:          host
			port:          listener.port
			ssl:           ssl_cfg
			admin_enabled: admin_enabled_override
		}
	}
	return MultiServerRuntimeConfig{
		single_mode: false
		listeners:   resolve_multi_server_targets(args, plan, targets)!
	}
}

struct MultiServerResolveTarget {
	id            string
	site_id       string
	cfg           config.VhttpdConfig
	host          string
	port          int
	ssl           config.ServerSslConfig
	admin_enabled bool
}

fn resolve_multi_server_targets(args []string, plan runtime_plan.RuntimePlan, targets []MultiServerResolveTarget) ![]ListenerRuntimeBinding {
	ids := targets.map(it.id)
	mut resolved := map[string]ServerRuntimeConfig{}
	mut owned := []executor.LogicExecutorRuntimePlan{}
	mut transferred := false
	defer {
		if !transferred {
			for item in owned { item.executor.close() }
		}
	}
	// Every actual owner is resolved first, including forward references.
	for target in targets {
		if plan.listener_app_owner_id(target.id, ids) != target.id { continue }
		cfg := ServerRuntimeConfig.resolve_for_target_with_plan(args, target.cfg, target.id,
			target.site_id, target.host, target.port, target.ssl, target.admin_enabled, plan, target.id)!
		resolved[target.id] = cfg
		owned << cfg.executor_plan
	}
	for target in targets {
		owner_id := plan.listener_app_owner_id(target.id, ids)
		if owner_id == target.id { continue }
		owner := resolved[owner_id] or { return error('missing_app_owner:${owner_id}') }
		resolved_plan := config.runtime_plan_apply_cli_overrides(args, target.cfg, plan, target.id)
		resolved[target.id] = resolve_server_runtime_target(args, target.cfg, target.id,
			target.site_id, target.host, target.port, target.ssl, target.admin_enabled,
			resolved_plan, target.id, owner.executor_plan)!
	}
	mut bindings := []ListenerRuntimeBinding{cap: targets.len}
	for target in targets {
		bindings << ListenerRuntimeBinding{
			id:          target.id
			site_id:     target.site_id
			site_cfg:    target.cfg
			runtime_cfg: resolved[target.id] or { return error('missing_runtime_config:${target.id}') }
		}
	}
	transferred = true
	return bindings
}

// A resolved configuration owns its primary executors until Apps take them.
// Startup/preflight failures release each real owner once; aliases only borrow.
pub fn (cfg MultiServerRuntimeConfig) close_untransferred_executors() {
	ids := cfg.listeners.map(it.runtime_cfg.plan_listener_id)
	for listener in cfg.listeners {
		runtime_cfg := listener.runtime_cfg
		if runtime_cfg.plan.listener_app_owner_id(runtime_cfg.plan_listener_id, ids) == runtime_cfg.plan_listener_id {
			runtime_cfg.executor_plan.executor.close()
		}
	}
}
