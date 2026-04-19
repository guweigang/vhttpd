module main

import os

pub struct ListenerRuntimeBinding {
pub:
	id          string
	site_id     string
	site_cfg    VhttpdConfig
	runtime_cfg ServerRuntimeConfig
}

pub struct MultiServerRuntimeConfig {
pub:
	single_mode bool
	listeners   []ListenerRuntimeBinding
}

fn config_uses_multi_listener(cfg VhttpdConfig) bool {
	return cfg.listeners.len > 0 || cfg.sites.len > 0
}

fn merge_paths_config(base PathsConfig, override PathsConfig) PathsConfig {
	defaults := default_vhttpd_config().paths
	mut cfg := base
	if override.root.trim_space() != '' && override.root != defaults.root {
		cfg.root = override.root
	}
	if override.values.len > 0 {
		cfg.values = override.values.clone()
	}
	return cfg
}

fn merge_worker_config(base WorkerConfig, override WorkerConfig) WorkerConfig {
	defaults := default_vhttpd_config().worker
	mut cfg := base
	if override.read_timeout_ms != defaults.read_timeout_ms {
		cfg.read_timeout_ms = override.read_timeout_ms
	}
	if override.autostart != defaults.autostart {
		cfg.autostart = override.autostart
	}
	if override.cmd != defaults.cmd {
		cfg.cmd = override.cmd
	}
	if override.stream_dispatch != defaults.stream_dispatch {
		cfg.stream_dispatch = override.stream_dispatch
	}
	if override.queue_capacity != defaults.queue_capacity {
		cfg.queue_capacity = override.queue_capacity
	}
	if override.queue_timeout_ms != defaults.queue_timeout_ms {
		cfg.queue_timeout_ms = override.queue_timeout_ms
	}
	if override.restart_backoff_ms != defaults.restart_backoff_ms {
		cfg.restart_backoff_ms = override.restart_backoff_ms
	}
	if override.restart_backoff_max_ms != defaults.restart_backoff_max_ms {
		cfg.restart_backoff_max_ms = override.restart_backoff_max_ms
	}
	if override.max_requests != defaults.max_requests {
		cfg.max_requests = override.max_requests
	}
	if override.socket != defaults.socket {
		cfg.socket = override.socket
	}
	if override.pool_size != defaults.pool_size {
		cfg.pool_size = override.pool_size
	}
	if override.websocket_dispatch != defaults.websocket_dispatch {
		cfg.websocket_dispatch = override.websocket_dispatch
	}
	if override.socket_prefix != defaults.socket_prefix {
		cfg.socket_prefix = override.socket_prefix
	}
	if override.sockets.len > 0 {
		cfg.sockets = override.sockets.clone()
	}
	if override.env.len > 0 {
		cfg.env = override.env.clone()
	}
	return cfg
}

fn merge_executor_config(base ExecutorConfig, override ExecutorConfig, site_cfg SiteConfig) ExecutorConfig {
	defaults := default_vhttpd_config().executor
	mut cfg := base
	if override.kind != defaults.kind {
		cfg.kind = override.kind
		return cfg
	}
	if site_cfg.php.app_entry.trim_space() != '' || site_cfg.php.worker_entry.trim_space() != ''
		|| site_cfg.worker_entry.trim_space() != '' {
		cfg.kind = 'php'
	} else if site_cfg.app.trim_space().to_lower().ends_with('.php') {
		cfg.kind = 'php'
	} else if site_cfg.vjsx.app_entry.trim_space() != ''
		|| site_cfg.vjsx.module_root.trim_space() != ''
		|| site_cfg.vjsx.build_root.trim_space() != '' {
		cfg.kind = 'vjsx'
	} else if site_cfg.app.trim_space() != '' {
		cfg.kind = 'vjsx'
	}
	return cfg
}

fn merge_php_config(base PhpConfig, override PhpConfig) PhpConfig {
	defaults := default_vhttpd_config().php
	mut cfg := base
	if override.bin != defaults.bin {
		cfg.bin = override.bin
	}
	if override.worker_entry != defaults.worker_entry {
		cfg.worker_entry = override.worker_entry
	}
	if override.app_entry != defaults.app_entry {
		cfg.app_entry = override.app_entry
	}
	if override.extensions.len > 0 {
		cfg.extensions = override.extensions.clone()
	}
	if override.args.len > 0 {
		cfg.args = override.args.clone()
	}
	return cfg
}

fn merge_vjsx_config(base VjsxConfig, override VjsxConfig) VjsxConfig {
	defaults := default_vhttpd_config().vjsx
	mut cfg := base
	if override.app_entry != defaults.app_entry {
		cfg.app_entry = override.app_entry
	}
	if override.module_root != defaults.module_root {
		cfg.module_root = override.module_root
	}
	if override.build_root != defaults.build_root {
		cfg.build_root = override.build_root
	}
	if override.signature_root != defaults.signature_root {
		cfg.signature_root = override.signature_root
	}
	if override.signature_include.len > 0 {
		cfg.signature_include = override.signature_include.clone()
	}
	if override.signature_exclude.len > 0 {
		cfg.signature_exclude = override.signature_exclude.clone()
	}
	if override.runtime_profile != defaults.runtime_profile {
		cfg.runtime_profile = override.runtime_profile
	}
	if override.thread_count != defaults.thread_count {
		cfg.thread_count = override.thread_count
	}
	if override.max_requests != defaults.max_requests {
		cfg.max_requests = override.max_requests
	}
	if override.enable_fs != defaults.enable_fs {
		cfg.enable_fs = override.enable_fs
	}
	if override.enable_process != defaults.enable_process {
		cfg.enable_process = override.enable_process
	}
	if override.enable_network != defaults.enable_network {
		cfg.enable_network = override.enable_network
	}
	return cfg
}

fn merge_websocket_affinity_config(base WebSocketAffinityConfig, override WebSocketAffinityConfig) WebSocketAffinityConfig {
	defaults := default_vhttpd_config().websocket_affinity
	mut cfg := base
	if override.enabled != defaults.enabled {
		cfg.enabled = override.enabled
	}
	if override.source != defaults.source {
		cfg.source = override.source
	}
	if override.key != defaults.key {
		cfg.key = override.key
	}
	if override.scope != defaults.scope {
		cfg.scope = override.scope
	}
	if override.fallback != defaults.fallback {
		cfg.fallback = override.fallback
	}
	return cfg
}

fn merge_assets_config(base AssetsConfig, override AssetsConfig) AssetsConfig {
	defaults := default_vhttpd_config().assets
	mut cfg := base
	if override.enabled != defaults.enabled {
		cfg.enabled = override.enabled
	}
	if override.prefix != defaults.prefix {
		cfg.prefix = override.prefix
	}
	if override.root != defaults.root {
		cfg.root = override.root
	}
	if override.cache_control != defaults.cache_control {
		cfg.cache_control = override.cache_control
	}
	return cfg
}

fn merge_runtime_config(base RuntimeConfig, override RuntimeConfig) RuntimeConfig {
	defaults := default_vhttpd_config().runtime
	mut cfg := base
	if override.timezone != defaults.timezone {
		cfg.timezone = override.timezone
	}
	return cfg
}

fn merge_mcp_config(base McpConfig, override McpConfig) McpConfig {
	defaults := default_vhttpd_config().mcp
	mut cfg := base
	if override.max_sessions != defaults.max_sessions {
		cfg.max_sessions = override.max_sessions
	}
	if override.max_pending_messages != defaults.max_pending_messages {
		cfg.max_pending_messages = override.max_pending_messages
	}
	if override.session_ttl_seconds != defaults.session_ttl_seconds {
		cfg.session_ttl_seconds = override.session_ttl_seconds
	}
	if override.allowed_origins.len > 0 {
		cfg.allowed_origins = override.allowed_origins.clone()
	}
	if override.sampling_capability_policy != defaults.sampling_capability_policy {
		cfg.sampling_capability_policy = override.sampling_capability_policy
	}
	return cfg
}

fn merge_feishu_config(base FeishuConfig, override FeishuConfig) FeishuConfig {
	defaults := default_vhttpd_config().feishu
	mut cfg := base
	if override.enabled != defaults.enabled {
		cfg.enabled = override.enabled
	}
	if override.open_base_url != defaults.open_base_url {
		cfg.open_base_url = override.open_base_url
	}
	if override.reconnect_delay_ms != defaults.reconnect_delay_ms {
		cfg.reconnect_delay_ms = override.reconnect_delay_ms
	}
	if override.token_refresh_skew_seconds != defaults.token_refresh_skew_seconds {
		cfg.token_refresh_skew_seconds = override.token_refresh_skew_seconds
	}
	if override.recent_event_limit != defaults.recent_event_limit {
		cfg.recent_event_limit = override.recent_event_limit
	}
	if override.apps.len > 0 {
		cfg.apps = override.apps.clone()
	}
	return cfg
}

fn merge_codex_config(base CodexConfig, override CodexConfig) CodexConfig {
	defaults := default_vhttpd_config().codex
	mut cfg := base
	if override.enabled != defaults.enabled {
		cfg.enabled = override.enabled
	}
	if override.url != defaults.url {
		cfg.url = override.url
	}
	if override.model != defaults.model {
		cfg.model = override.model
	}
	if override.effort != defaults.effort {
		cfg.effort = override.effort
	}
	if override.cwd != defaults.cwd {
		cfg.cwd = override.cwd
	}
	if override.approval_policy != defaults.approval_policy {
		cfg.approval_policy = override.approval_policy
	}
	if override.sandbox != defaults.sandbox {
		cfg.sandbox = override.sandbox
	}
	if override.reconnect_delay_ms != defaults.reconnect_delay_ms {
		cfg.reconnect_delay_ms = override.reconnect_delay_ms
	}
	if override.flush_interval_ms != defaults.flush_interval_ms {
		cfg.flush_interval_ms = override.flush_interval_ms
	}
	return cfg
}

fn merge_bridge_config(base BridgeConfig, override BridgeConfig) BridgeConfig {
	defaults := default_vhttpd_config().feishu.bridge
	mut cfg := base
	if override.enabled != defaults.enabled {
		cfg.enabled = override.enabled
	}
	if override.ws_url != defaults.ws_url {
		cfg.ws_url = override.ws_url
	}
	if override.client_id != defaults.client_id {
		cfg.client_id = override.client_id
	}
	if override.token != defaults.token {
		cfg.token = override.token
	}
	if override.target_id != defaults.target_id {
		cfg.target_id = override.target_id
	}
	return cfg
}

fn site_config_as_vhttpd_config(global_cfg VhttpdConfig, site_cfg SiteConfig) VhttpdConfig {
	mut cfg := global_cfg
	cfg.listeners = map[string]ListenerConfig{}
	cfg.sites = map[string]SiteConfig{}
	cfg.paths = merge_paths_config(global_cfg.paths, site_cfg.paths)
	if site_cfg.project_root.trim_space() != '' {
		mut project_root := site_cfg.project_root
		global_vars := build_config_variable_map(global_cfg)
		env_map := os.environ()
		project_root, _ = expand_config_string(project_root, '', global_vars, env_map,
			false) or { site_cfg.project_root, false }
		cfg.paths = PathsConfig{
			root:   project_root
			values: cfg.paths.values.clone()
		}
	}
	cfg.worker = merge_worker_config(global_cfg.worker, site_cfg.worker)
	cfg.executor = merge_executor_config(global_cfg.executor, site_cfg.executor, site_cfg)
	cfg.php = merge_php_config(global_cfg.php, site_cfg.php)
	cfg.vjsx = merge_vjsx_config(global_cfg.vjsx, site_cfg.vjsx)
	cfg.websocket_affinity = merge_websocket_affinity_config(global_cfg.websocket_affinity,
		site_cfg.websocket_affinity)
	if site_cfg.worker_entry.trim_space() != '' && cfg.executor.kind == 'php'
		&& cfg.php.worker_entry.trim_space() == '' {
		cfg.php.worker_entry = site_cfg.worker_entry
	}
	if site_cfg.app.trim_space() != '' {
		if cfg.executor.kind == 'php' && cfg.php.app_entry.trim_space() == '' {
			cfg.php.app_entry = site_cfg.app
		}
		if cfg.executor.kind == 'vjsx' && cfg.vjsx.app_entry.trim_space() == '' {
			cfg.vjsx.app_entry = site_cfg.app
		}
	}
	if cfg.executor.kind == 'vjsx' && cfg.vjsx.module_root.trim_space() == '' {
		cfg.vjsx.module_root = cfg.paths.root
	}
	cfg.assets = merge_assets_config(global_cfg.assets, site_cfg.assets)
	cfg.runtime = merge_runtime_config(global_cfg.runtime, site_cfg.runtime)
	cfg.mcp = merge_mcp_config(global_cfg.mcp, site_cfg.mcp)
	cfg.feishu = merge_feishu_config(global_cfg.feishu, site_cfg.feishu)
	cfg.codex = merge_codex_config(global_cfg.codex, site_cfg.codex)
	cfg.feishu.bridge = merge_bridge_config(global_cfg.feishu.bridge, site_cfg.feishu.bridge)
	cfg.config_path = global_cfg.config_path
	return cfg
}

fn resolve_multi_listener_specs(cfg VhttpdConfig) !map[string]ListenerConfig {
	if cfg.sites.len == 0 {
		return error('multi_listener_missing_sites')
	}
	if cfg.listeners.len > 0 {
		return cfg.listeners.clone()
	}
	mut listener_ids := cfg.sites.keys()
	listener_ids.sort()
	mut listeners := map[string]ListenerConfig{}
	for site_id in listener_ids {
		site_cfg := cfg.sites[site_id]
		if site_cfg.port <= 0 {
			return error('multi_listener_missing_port:${site_id}')
		}
		listeners[site_id] = ListenerConfig{
			host: if site_cfg.host.trim_space() == '' { '127.0.0.1' } else { site_cfg.host }
			port: site_cfg.port
			site: site_id
		}
	}
	return listeners
}

fn resolve_multi_server_runtime_config(args []string, cfg VhttpdConfig) !MultiServerRuntimeConfig {
	if !config_uses_multi_listener(cfg) {
		return MultiServerRuntimeConfig{
			single_mode: true
			listeners:   [
				ListenerRuntimeBinding{
					id:          'default'
					site_id:     'default'
					site_cfg:    cfg
					runtime_cfg: resolve_server_runtime_config(args, cfg)!
				},
			]
		}
	}
	if cfg.listeners.len == 0 {
		if cfg.sites.len == 0 {
			return error('multi_listener_missing_sites')
		}
	}
	listeners := resolve_multi_listener_specs(cfg)!
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
		mut site_runtime_cfg := site_config_as_vhttpd_config(cfg, cfg.sites[site_id])
		if site_runtime_cfg.config_path != '' {
			resolve_config_variables(mut site_runtime_cfg, site_runtime_cfg.config_path)!
		}
		admin_enabled_override := listener_id == admin_owner_listener_id
		runtime_cfg := resolve_server_runtime_config_for_target(args, site_runtime_cfg,
			listener_id, site_id, listener_cfg.host, listener_cfg.port, admin_enabled_override)!
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
