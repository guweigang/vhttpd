module config

pub fn (cfg VhttpdConfig) uses_multi_listener() bool {
	return cfg.listeners.len > 0 || cfg.sites.len > 0
}

pub fn (cfg VhttpdConfig) default_site_id() string {
	if cfg.site.name.trim_space() != '' {
		return cfg.site.name.trim_space()
	}
	return 'default'
}

pub fn (cfg VhttpdConfig) canonical_sites() map[string]SiteConfig {
	if cfg.sites.len > 0 {
		return cfg.sites.clone()
	}
	mut site_cfg := cfg.site
	if site_cfg.executors.len == 0 && cfg.executors.len > 0 {
		site_cfg.executors = cfg.executors.clone()
	}
	if site_cfg.routes.len == 0 && cfg.routes.len > 0 {
		site_cfg.routes = cfg.routes.clone()
	}
	return {
		cfg.default_site_id(): site_cfg
	}
}

pub fn (base PathsConfig) merge(override PathsConfig) PathsConfig {
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

pub fn (base WorkerConfig) merge(override WorkerConfig) WorkerConfig {
	defaults := default_vhttpd_config().worker
	mut cfg := base
	cfg.env = base.env.clone()
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

pub fn (base ExecutorConfig) merge(override ExecutorConfig, site_cfg SiteConfig) ExecutorConfig {
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

pub fn (base PhpConfig) merge(override PhpConfig) PhpConfig {
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

pub fn (base PhpSiteConfig) merge(override PhpSiteConfig) PhpSiteConfig {
	mut cfg := base
	if override.deny_php.len > 0 {
		cfg.deny_php = override.deny_php.clone()
	}
	if override.compat_php.len > 0 {
		cfg.compat_php = override.compat_php.clone()
	}
	return cfg
}

fn escape_regex_literal(s string) string {
	mut out := ''
	for ch in s {
		c := ch.ascii_str()
		if c in ['\\', '.', '+', '?', '^', '$', '(', ')', '[', ']', '{', '}', '|'] {
			out += '\\' + c
		} else if c == '*' {
			out += '.*'
		} else {
			out += c
		}
	}
	return out
}

fn php_deny_rule_for_pattern(pattern string) RouteRuleConfig {
	trimmed := pattern.trim_space()
	if trimmed == '' {
		return RouteRuleConfig{}
	}
	if trimmed.ends_with('.php') && !trimmed.contains('*') {
		return RouteRuleConfig{
			match:  RouteMatchConfig{
				path: [trimmed]
			}
			status: 403
			body:   'Forbidden: Access denied.'
		}
	}
	mut base := trimmed
	if base.ends_with('/*') {
		base = base[..base.len - 2]
	}
	if base.ends_with('/') {
		base = base[..base.len - 1]
	}
	return RouteRuleConfig{
		match:  RouteMatchConfig{
			path_regexp: '^' + escape_regex_literal(base) + '/.*\\.php$'
		}
		status: 403
		body:   'Forbidden: Access denied.'
	}
}

pub fn expand_php_site_routes(cfg VhttpdConfig) []RouteRuleConfig {
	mut expanded := []RouteRuleConfig{}
	for pattern in cfg.php_site.deny_php {
		rule := php_deny_rule_for_pattern(pattern)
		if rule.match.path.len > 0 || rule.match.path_regexp != '' {
			expanded << rule
		}
	}
	expanded << cfg.routes.clone()
	if cfg.php_site.compat_php.len > 0 {
		expanded << RouteRuleConfig{
			match:    RouteMatchConfig{
				path: cfg.php_site.compat_php.clone()
			}
			executor: 'php-cgi'
		}
	}
	return expanded
}

pub fn (base VjsxConfig) merge(override VjsxConfig) VjsxConfig {
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

pub fn PluginConfig.merge_map(base map[string]PluginConfig, override map[string]PluginConfig) map[string]PluginConfig {
	if override.len == 0 {
		return base.clone()
	}
	return override.clone()
}

pub fn (base WebSocketAffinityConfig) merge(override WebSocketAffinityConfig) WebSocketAffinityConfig {
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

pub fn (base WebSocketActorConfig) merge(override WebSocketActorConfig) WebSocketActorConfig {
	defaults := default_vhttpd_config().websocket_actor
	mut cfg := base
	if override.enabled != defaults.enabled {
		cfg.enabled = override.enabled
	}
	if override.sources.len > 0 {
		cfg.sources = override.sources.clone()
	}
	if override.fallback != defaults.fallback {
		cfg.fallback = override.fallback
	}
	if override.queue_timeout_ms != defaults.queue_timeout_ms {
		cfg.queue_timeout_ms = override.queue_timeout_ms
	}
	if override.max_queue_per_key != defaults.max_queue_per_key {
		cfg.max_queue_per_key = override.max_queue_per_key
	}
	if override.events.len > 0 {
		cfg.events = override.events.clone()
	}
	return cfg
}

pub fn (base AssetsConfig) merge(override AssetsConfig) AssetsConfig {
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

pub fn (base RuntimeConfig) merge(override RuntimeConfig) RuntimeConfig {
	defaults := default_vhttpd_config().runtime
	mut cfg := base
	if override.timezone != defaults.timezone {
		cfg.timezone = override.timezone
	}
	return cfg
}

pub fn (base McpConfig) merge(override McpConfig) McpConfig {
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

pub fn (base FeishuConfig) merge(override FeishuConfig) FeishuConfig {
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

pub fn (base CodexConfig) merge(override CodexConfig) CodexConfig {
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

pub fn (base BridgeConfig) merge(override BridgeConfig) BridgeConfig {
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

pub fn (base DbMysqlConfig) merge(override DbMysqlConfig) DbMysqlConfig {
	defaults := default_vhttpd_config().db.mysql
	mut cfg := base
	if override.host != defaults.host {
		cfg.host = override.host
	}
	if override.port != defaults.port {
		cfg.port = override.port
	}
	if override.username != defaults.username {
		cfg.username = override.username
	}
	if override.password != defaults.password {
		cfg.password = override.password
	}
	if override.database != defaults.database {
		cfg.database = override.database
	}
	if override.pool_size != defaults.pool_size {
		cfg.pool_size = override.pool_size
	}
	if override.idle_ping_ms != defaults.idle_ping_ms {
		cfg.idle_ping_ms = override.idle_ping_ms
	}
	if override.init_sql != defaults.init_sql {
		cfg.init_sql = override.init_sql.clone()
	}
	return cfg
}

pub fn (base DbPgsqlConfig) merge(override DbPgsqlConfig) DbPgsqlConfig {
	defaults := default_vhttpd_config().db.pgsql
	mut cfg := base
	if override.host != defaults.host {
		cfg.host = override.host
	}
	if override.port != defaults.port {
		cfg.port = override.port
	}
	if override.username != defaults.username {
		cfg.username = override.username
	}
	if override.password != defaults.password {
		cfg.password = override.password
	}
	if override.database != defaults.database {
		cfg.database = override.database
	}
	if override.pool_size != defaults.pool_size {
		cfg.pool_size = override.pool_size
	}
	return cfg
}

pub fn (base DbConfig) merge(override DbConfig) DbConfig {
	defaults := default_vhttpd_config().db
	mut cfg := base
	if override.enabled != defaults.enabled {
		cfg.enabled = override.enabled
	}
	if override.socket != defaults.socket {
		cfg.socket = override.socket
	}
	if override.driver != defaults.driver {
		cfg.driver = override.driver
	}
	if override.pool_name != defaults.pool_name {
		cfg.pool_name = override.pool_name
	}
	cfg.mysql = base.mysql.merge(override.mysql)
	cfg.pgsql = base.pgsql.merge(override.pgsql)
	return cfg
}

pub fn (base OpenAIConfig) merge(override OpenAIConfig) OpenAIConfig {
	defaults := default_vhttpd_config().openai
	mut cfg := base
	if override.enabled != defaults.enabled {
		cfg.enabled = override.enabled
	}
	if override.base_path != defaults.base_path {
		cfg.base_path = override.base_path
	}
	if override.default_backend != defaults.default_backend {
		cfg.default_backend = override.default_backend
	}
	if override.endpoints.models != defaults.endpoints.models {
		cfg.endpoints.models = override.endpoints.models
	}
	if override.endpoints.chat_completions != defaults.endpoints.chat_completions {
		cfg.endpoints.chat_completions = override.endpoints.chat_completions
	}
	if override.endpoints.responses != defaults.endpoints.responses {
		cfg.endpoints.responses = override.endpoints.responses
	}
	if override.endpoints.embeddings != defaults.endpoints.embeddings {
		cfg.endpoints.embeddings = override.endpoints.embeddings
	}
	if override.backends.len > 0 {
		cfg.backends = override.backends.clone()
	}
	if override.routes.len > 0 {
		cfg.routes = override.routes.clone()
	}
	return cfg
}

pub fn (global_cfg VhttpdConfig) with_site(site_cfg SiteConfig) VhttpdConfig {
	mut cfg := global_cfg
	cfg.listeners = map[string]ListenerConfig{}
	cfg.sites = map[string]SiteConfig{}
	cfg.site = site_cfg
	cfg.paths = global_cfg.paths.merge(site_cfg.paths)
	if site_cfg.project_root.trim_space() != '' {
		mut project_root := site_cfg.project_root
		global_vars := build_config_variable_map(global_cfg)
		env_map := map[string]string{}
		project_root, _ = expand_config_string(project_root, '', global_vars, env_map, false) or {
			site_cfg.project_root, false
		}
		project_root = resolve_config_path(global_cfg.paths.root, project_root)
		cfg.paths = PathsConfig{
			root:   project_root
			values: cfg.paths.values.clone()
		}
	}
	if cfg.site.document_root.trim_space() == '' {
		cfg.site.document_root = cfg.paths.root
	}
	cfg.server.ssl = global_cfg.server.ssl.merge(site_cfg.ssl)
	cfg.worker = global_cfg.worker.merge(site_cfg.worker)
	if cfg.site.document_root.trim_space() != '' && cfg.worker.env['DOCUMENT_ROOT'] == '' {
		cfg.worker.env['DOCUMENT_ROOT'] = cfg.site.document_root
	}
	cfg.executor = global_cfg.executor.merge(site_cfg.executor, site_cfg)
	cfg.php = global_cfg.php.merge(site_cfg.php)
	cfg.php_site = global_cfg.php_site.merge(site_cfg.php_site)
	cfg.vjsx = global_cfg.vjsx.merge(site_cfg.vjsx)
	cfg.plugins = PluginConfig.merge_map(global_cfg.plugins, site_cfg.plugins)
	cfg.websocket_affinity = global_cfg.websocket_affinity.merge(site_cfg.websocket_affinity)
	cfg.websocket_actor = global_cfg.websocket_actor.merge(site_cfg.websocket_actor)
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
	cfg.assets = global_cfg.assets.merge(site_cfg.assets)
	cfg.runtime = global_cfg.runtime.merge(site_cfg.runtime)
	cfg.mcp = global_cfg.mcp.merge(site_cfg.mcp)
	cfg.feishu = global_cfg.feishu.merge(site_cfg.feishu)
	cfg.codex = global_cfg.codex.merge(site_cfg.codex)
	cfg.openai = global_cfg.openai.merge(site_cfg.openai)
	cfg.db = global_cfg.db.merge(site_cfg.db)
	cfg.feishu.bridge = global_cfg.feishu.bridge.merge(site_cfg.feishu.bridge)
	if site_cfg.routes.len > 0 {
		cfg.routes = site_cfg.routes.clone()
	}
	if site_cfg.executors.len > 0 {
		cfg.executors = site_cfg.executors.clone()
	}
	cfg.config_path = global_cfg.config_path
	return cfg.with_default_executor_from_named_executor()
}

pub fn (cfg VhttpdConfig) with_default_executor_from_named_executor() VhttpdConfig {
	default_executor := cfg.site.default_executor.trim_space()
	if default_executor == '' {
		return cfg
	}
	spec := cfg.executors[default_executor] or { return cfg }
	mut next := cfg
	if spec.executor.kind.trim_space() != '' {
		next.executor = spec.executor
	} else if next.executor.kind.trim_space() == '' {
		next.executor.kind = default_executor
	}
	next.worker = next.worker.merge(spec.worker)
	next.php = next.php.merge(spec.php)
	next.php_site = next.php_site.merge(spec.php_site)
	next.vjsx = next.vjsx.merge(spec.vjsx)
	return next
}

pub fn (cfg VhttpdConfig) resolve_multi_listeners() !map[string]ListenerConfig {
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
			ssl:  site_cfg.ssl
		}
	}
	return listeners
}

pub fn (base ServerSslConfig) merge(override ServerSslConfig) ServerSslConfig {
	defaults := default_vhttpd_config().server.ssl
	mut cfg := base
	if override.enabled != defaults.enabled {
		cfg.enabled = override.enabled
	}
	if override.cert != defaults.cert {
		cfg.cert = override.cert
	}
	if override.cert_key != defaults.cert_key {
		cfg.cert_key = override.cert_key
	}
	return cfg
}
