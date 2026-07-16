module config

import runtime_plan

pub fn compile_v1_runtime_plan(cfg VhttpdConfig) !runtime_plan.RuntimePlan {
	v2 := compile_v1_to_v2(cfg)!
	return compile_v2_runtime_plan_with_diagnostics(v2, cfg.config_path, true,
		v1_plan_diagnostics(cfg))
}

fn v1_plan_diagnostics(cfg VhttpdConfig) []runtime_plan.PlanDiagnostic {
	mut diagnostics := [
		runtime_plan.PlanDiagnostic{
			severity: 'warning'
			code:     'legacy_schema'
			path:     '$'
			message:  'V1 configuration was compiled through the compatibility layer'
		},
	]
	if cfg.paths.root != '.' || cfg.paths.values.len > 0 {
		diagnostics << runtime_plan.PlanDiagnostic{
			severity: 'info'
			code:     'compile_only_paths'
			path:     'paths'
			message:  'path variables are resolved before RuntimePlan compilation'
		}
	}
	for index, route in cfg.routes {
		if route.executor in ['static', 'upload', 'none'] {
			diagnostics << runtime_plan.PlanDiagnostic{
				severity: 'info'
				code:     'legacy_magic_executor'
				path:     'routes[${index}].executor'
				message:  'legacy executor ${route.executor} was compiled into an adapter or terminal'
			}
		}
		if route.on_completed.trim_space().starts_with('vjsx:') {
			diagnostics << runtime_plan.PlanDiagnostic{
				severity: 'info'
				code:     'legacy_completion_handler'
				path:     'routes[${index}].on_completed'
				message:  'legacy completion handler was compiled into an event pipeline'
			}
		}
	}
	return diagnostics
}

pub fn compile_v1_to_v2(cfg VhttpdConfig) !V2Config {
	mut target := V2Config{
		server:        V2ServerSpec{
			timezone: cfg.runtime.timezone
			pid_file: cfg.files.pid_file
		}
		observability: V2ObservabilitySpec{
			event_log: cfg.files.event_log
			log_level: 'info'
		}
	}
	target.providers = v1_provider_specs(cfg)
	if cfg.admin.port > 0 {
		target.listeners['control'] = V2ListenerSpec{
			protocol:  'http'
			transport: 'tcp'
			host:      cfg.admin.host
			port:      cfg.admin.port
		}
		target.control = V2ControlSpec{
			listener: 'listener:control'
			token:    cfg.admin.token
		}
	}
	if !cfg.uses_multi_listener() {
		site_id := cfg.default_site_id()
		listener_id := 'default'
		target.listeners[listener_id] = v1_listener_spec(cfg.server.host, cfg.server.port,
			cfg.server.ssl)
		compile_v1_site(cfg, site_id, listener_id, mut target)!
		return target
	}
	listeners := cfg.resolve_multi_listeners()!
	mut listener_ids := listeners.keys()
	listener_ids.sort()
	for listener_id in listener_ids {
		listener := listeners[listener_id]
		site_id := listener.site.trim_space()
		if site_id == '' || site_id !in cfg.sites {
			return error('multi_listener_unknown_site:${listener_id}:${site_id}')
		}
		site_cfg := cfg.with_site(cfg.sites[site_id])
		ssl := if listener.ssl.enabled || listener.ssl.cert != '' || listener.ssl.cert_key != '' {
			listener.ssl
		} else {
			site_cfg.server.ssl
		}
		target.listeners[listener_id] = v1_listener_spec(listener.host, listener.port, ssl)
		compile_v1_site(site_cfg, site_id, listener_id, mut target)!
	}
	return target
}

fn v1_provider_specs(cfg VhttpdConfig) map[string]V2ProviderSpec {
	mut providers := map[string]V2ProviderSpec{}
	for name, provider_cfg in cfg.providers {
		providers[name] = V2ProviderSpec{
			runtime:        V2ProviderRuntimeSpec{
				driver: provider_cfg.runtime.driver
				plugin: provider_cfg.runtime.plugin
			}
			capabilities:   provider_cfg.capabilities.clone()
			runtime_driver: provider_cfg.runtime_driver
			runtime_plugin: provider_cfg.runtime_plugin
		}
	}
	feishu_driver := cfg.feishu.runtime_driver.trim_space()
	feishu_plugin := cfg.feishu.runtime_plugin.trim_space()
	if feishu_plugin != '' || (feishu_driver != '' && feishu_driver != 'native') {
		existing := providers['feishu'] or { V2ProviderSpec{} }
		providers['feishu'] = V2ProviderSpec{
			...existing
			runtime:        V2ProviderRuntimeSpec{
				driver: if feishu_driver != '' { feishu_driver } else { existing.runtime.driver }
				plugin: if feishu_plugin != '' { feishu_plugin } else { existing.runtime.plugin }
			}
			runtime_driver: if feishu_driver != '' { feishu_driver } else { existing.runtime_driver }
			runtime_plugin: if feishu_plugin != '' { feishu_plugin } else { existing.runtime_plugin }
		}
	}
	return providers
}

fn v1_listener_spec(host string, port int, ssl ServerSslConfig) V2ListenerSpec {
	return V2ListenerSpec{
		protocol:  'http'
		transport: 'tcp'
		host:      host
		port:      port
		tls:       V2TlsSpec{
			enabled:  ssl.enabled
			cert:     ssl.cert
			cert_key: ssl.cert_key
		}
	}
}

fn compile_v1_site(cfg VhttpdConfig, site_id string, listener_id string, mut target V2Config) ! {
	scope := safe_plan_id(site_id)
	resource_refs := compile_v1_resources(cfg, scope, mut target)
	default_engine_id := '${scope}/default'
	default_adapter_id := '${scope}/default'
	if default_engine_id !in target.engines {
		target.engines[default_engine_id] = v1_engine_spec(cfg.executor.kind, cfg.worker, cfg.php,
			cfg.vjsx, resource_refs)
		target.adapters[default_adapter_id] = V2AdapterSpec{
			kind:          'http-handler'
			engine:        'engine:${default_engine_id}'
			document_root: cfg.site.document_root
			index:         if cfg.site.index != '' { cfg.site.index } else { cfg.server.index }
		}
		mut executor_names := cfg.executors.keys()
		executor_names.sort()
		for name in executor_names {
			spec := cfg.executors[name]
			engine_id := '${scope}/${safe_plan_id(name)}'
			target.engines[engine_id] = v1_engine_spec(spec.executor.kind, spec.worker, spec.php,
				spec.vjsx, resource_refs)
			target.adapters[engine_id] = V2AdapterSpec{
				kind:          'http-handler'
				engine:        'engine:${engine_id}'
				document_root: cfg.site.document_root
				index:         if cfg.site.index != '' { cfg.site.index } else { cfg.server.index }
			}
		}
	}
	mut order := compile_v1_protocol_resources(cfg, scope, site_id, listener_id, mut target)
	if cfg.assets.enabled {
		adapter_id := '${scope}/assets'
		policy_id := 'cache/${scope}_assets'
		target.adapters[adapter_id] = V2AdapterSpec{
			kind: 'static'
			root: cfg.assets.root
		}
		target.policies.cache['${scope}_assets'] = V2CachePolicySpec{
			cache_control: cfg.assets.cache_control
		}
		prefix := normalize_v1_assets_prefix(cfg.assets.prefix)
		target.pipelines << V2PipelineSpec{
			id:       '${listener_id}/${order}_assets'
			group:    'site:${site_id}'
			ingress:  'listener:${listener_id}'
			match:    V2MatchSpec{
				methods: ['GET', 'HEAD']
				paths:   [prefix, '${prefix}/*']
			}
			policies: ['policy:${policy_id}']
			egress:   'adapter:${adapter_id}'
		}
		order++
	}
	routes := expand_php_site_routes(cfg)
	for route in routes {
		pipeline_id := '${listener_id}/${order}_route'
		mut transform_refs := []string{}
		if route.rewrite != '' || route.rewrite_strip_prefix != '' {
			transform_id := '${scope}/rewrite_${order}'
			target.transforms[transform_id] = V2TransformSpec{
				kind:         'native'
				handler:      'http.rewrite'
				target:       route.rewrite
				strip_prefix: route.rewrite_strip_prefix
			}
			transform_refs << 'transform:${transform_id}'
		}
		mut policy_refs := []string{}
		if route.cache_control != '' || route.response_cache_ttl_ms > 0
			|| route.cache_bypass_cookie_patterns.len > 0
			|| route.cache_ignore_cookie_patterns.len > 0 {
			policy_name := '${scope}_route_${order}'
			target.policies.cache[policy_name] = V2CachePolicySpec{
				cache_control:          route.cache_control
				ttl_ms:                 route.response_cache_ttl_ms
				bypass_cookie_patterns: route.cache_bypass_cookie_patterns.clone()
				ignore_cookie_patterns: route.cache_ignore_cookie_patterns.clone()
			}
			policy_refs << 'policy:cache/${policy_name}'
		}
		if route.max_body_bytes > 0 {
			policy_name := '${scope}_route_${order}'
			target.policies.limits[policy_name] = V2LimitPolicySpec{
				max_body_bytes: route.max_body_bytes
			}
			policy_refs << 'policy:limits/${policy_name}'
		}
		if route.required_headers.len > 0 || route.denied_query_patterns.len > 0 {
			policy_name := '${scope}_route_${order}'
			target.policies.security[policy_name] = V2SecurityPolicySpec{
				required_headers:      route.required_headers.clone()
				denied_query_patterns: route.denied_query_patterns.clone()
			}
			policy_refs << 'policy:security/${policy_name}'
		}
		if route.response_headers.len > 0 {
			policy_name := '${scope}_route_${order}'
			target.policies.response[policy_name] = V2ResponsePolicySpec{
				headers: route.response_headers.clone()
			}
			policy_refs << 'policy:response/${policy_name}'
		}
		egress := compile_v1_route_egress(route, cfg, scope, order, default_adapter_id,
			listener_id, site_id, mut target)
		target.pipelines << V2PipelineSpec{
			id:         pipeline_id
			group:      'site:${site_id}'
			ingress:    'listener:${listener_id}'
			match:      V2MatchSpec{
				methods:     route.match.method.clone()
				paths:       route.match.path.clone()
				path_regexp: route.match.path_regexp
				query:       string_map_to_list_map(route.match.query)
			}
			transforms: transform_refs
			policies:   policy_refs
			egress:     egress
		}
		order++
	}
	target.pipelines << V2PipelineSpec{
		id:      '${listener_id}/${order}_fallback'
		group:   'site:${site_id}'
		ingress: 'listener:${listener_id}'
		match:   V2MatchSpec{
			paths: ['*']
		}
		egress:  'adapter:${default_adapter_id}'
	}
}

fn string_map_to_list_map(values map[string]string) map[string][]string {
	mut out := map[string][]string{}
	for key, value in values {
		out[key] = [value]
	}
	return out
}

fn compile_v1_resources(cfg VhttpdConfig, scope string, mut target V2Config) []string {
	mut references := []string{}
	if cfg.db.enabled {
		target.resources.db[scope] = if cfg.db.driver == 'pgsql' {
			V2DbResourceSpec{
				kind:      'pgsql'
				host:      cfg.db.pgsql.host
				port:      cfg.db.pgsql.port
				database:  cfg.db.pgsql.database
				username:  cfg.db.pgsql.username
				password:  cfg.db.pgsql.password
				pool_size: cfg.db.pgsql.pool_size
			}
		} else {
			V2DbResourceSpec{
				kind:         'mysql'
				host:         cfg.db.mysql.host
				port:         cfg.db.mysql.port
				database:     cfg.db.mysql.database
				username:     cfg.db.mysql.username
				password:     cfg.db.mysql.password
				pool_size:    cfg.db.mysql.pool_size
				idle_ping_ms: cfg.db.mysql.idle_ping_ms
				init_sql:     cfg.db.mysql.init_sql.clone()
			}
		}
		target.resources.db[scope].options = {
			'socket':    cfg.db.socket
			'pool_name': cfg.db.pool_name
		}
		references << 'resource:db/${scope}'
	}
	if cfg.cache.enabled {
		target.resources.cache[scope] = V2CacheResourceSpec{
			kind:   'memory'
			socket: cfg.cache.socket
		}
		references << 'resource:cache/${scope}'
	}
	return references
}

fn compile_v1_protocol_resources(cfg VhttpdConfig, scope string, site_id string, listener_id string, mut target V2Config) int {
	mut order := 0
	mcp_adapter_id := '${scope}/mcp'
	target.adapters[mcp_adapter_id] = V2AdapterSpec{
		kind:         'mcp'
		int_options:  {
			'max_sessions':         cfg.mcp.max_sessions
			'max_pending_messages': cfg.mcp.max_pending_messages
			'session_ttl_seconds':  cfg.mcp.session_ttl_seconds
		}
		list_options: {
			'allowed_origins': cfg.mcp.allowed_origins.clone()
		}
		options:      {
			'sampling_capability_policy': cfg.mcp.sampling_capability_policy
		}
	}
	target.pipelines << V2PipelineSpec{
		id:      '${listener_id}/${order}_mcp'
		group:   'site:${site_id}'
		ingress: 'listener:${listener_id}'
		match:   V2MatchSpec{
			paths: ['/mcp']
		}
		egress:  'adapter:${mcp_adapter_id}'
	}
	order++

	if cfg.openai.enabled {
		adapter_id := '${scope}/openai'
		mut backend_records := []map[string]string{}
		mut backend_names := cfg.openai.backends.keys()
		backend_names.sort()
		for name in backend_names {
			backend := cfg.openai.backends[name]
			backend_records << {
				'id':          name
				'kind':        backend.kind
				'base_url':    backend.base_url
				'executor':    backend.executor
				'api_key':     backend.api_key
				'api_key_env': backend.api_key_env
				'timeout_ms':  backend.timeout_ms.str()
			}
		}
		mut route_records := []map[string]string{}
		mut route_models := map[string][]string{}
		mut route_names := cfg.openai.routes.keys()
		route_names.sort()
		for name in route_names {
			route := cfg.openai.routes[name]
			route_records << {
				'id':             name
				'model':          route.model
				'backend':        route.backend
				'upstream_model': route.upstream_model
			}
			route_models[name] = route.models.clone()
		}
		target.adapters[adapter_id] = V2AdapterSpec{
			kind:           'openai'
			options:        {
				'base_path':       cfg.openai.base_path
				'default_backend': cfg.openai.default_backend
				'plugin':          cfg.openai.plugin
			}
			bool_options:   {
				'endpoint_models':           cfg.openai.endpoints.models
				'endpoint_chat_completions': cfg.openai.endpoints.chat_completions
				'endpoint_responses':        cfg.openai.endpoints.responses
				'endpoint_embeddings':       cfg.openai.endpoints.embeddings
			}
			list_options:   route_models
			record_options: {
				'backends': backend_records
				'routes':   route_records
			}
		}
		base_path := if cfg.openai.base_path.trim_space() == '' {
			'/v1'
		} else {
			cfg.openai.base_path
		}
		target.pipelines << V2PipelineSpec{
			id:      '${listener_id}/${order}_openai'
			group:   'site:${site_id}'
			ingress: 'listener:${listener_id}'
			match:   V2MatchSpec{
				paths: [base_path, '${base_path}/*']
			}
			egress:  'adapter:${adapter_id}'
		}
		order++
	}

	if cfg.feishu.enabled || cfg.feishu.apps.len > 0 {
		mut app_records := []map[string]string{}
		mut app_names := cfg.feishu.apps.keys()
		app_names.sort()
		for name in app_names {
			app := cfg.feishu.apps[name]
			app_records << {
				'id':                 name
				'app_id':             app.app_id
				'app_secret':         app.app_secret
				'verification_token': app.verification_token
				'encrypt_key':        app.encrypt_key
			}
		}
		target.adapters['${scope}/feishu'] = V2AdapterSpec{
			kind:           'feishu-events'
			options:        {
				'open_base_url': cfg.feishu.open_base_url
			}
			int_options:    {
				'reconnect_delay_ms':         cfg.feishu.reconnect_delay_ms
				'token_refresh_skew_seconds': cfg.feishu.token_refresh_skew_seconds
				'recent_event_limit':         cfg.feishu.recent_event_limit
			}
			bool_options:   {
				'enabled': cfg.feishu.enabled
			}
			record_options: {
				'apps': app_records
			}
		}
	}

	if cfg.codex.enabled {
		target.adapters['${scope}/codex'] = V2AdapterSpec{
			kind:         'codex'
			options:      {
				'url':             cfg.codex.url
				'model':           cfg.codex.model
				'effort':          cfg.codex.effort
				'cwd':             cfg.codex.cwd
				'approval_policy': cfg.codex.approval_policy
				'sandbox':         cfg.codex.sandbox
			}
			int_options:  {
				'reconnect_delay_ms': cfg.codex.reconnect_delay_ms
				'flush_interval_ms':  cfg.codex.flush_interval_ms
			}
			bool_options: {
				'enabled': cfg.codex.enabled
			}
		}
	}

	mut plugin_names := cfg.plugins.keys()
	plugin_names.sort()
	for name in plugin_names {
		plugin := cfg.plugins[name]
		engine_id := '${scope}/plugin/${safe_plan_id(name)}'
		target.engines[engine_id] = V2EngineSpec{
			kind:              'vjsx'
			entry:             if plugin.app_entry != '' { plugin.app_entry } else { plugin.entry }
			module_root:       plugin.module_root
			build_root:        plugin.build_root
			runtime_profile:   plugin.runtime_profile
			thread_count:      plugin.thread_count
			max_requests:      plugin.max_requests
			enable_fs:         plugin.enable_fs
			enable_process:    plugin.enable_process
			enable_network:    plugin.enable_network
			signature_root:    plugin.signature_root
			signature_include: plugin.signature_include.clone()
			signature_exclude: plugin.signature_exclude.clone()
		}
		target.transforms['${scope}/plugin/${safe_plan_id(name)}'] = V2TransformSpec{
			kind:    if plugin.kind != '' { plugin.kind } else { 'vjsx' }
			engine:  'engine:${engine_id}'
			handler: name
		}
	}

	if cfg.websocket_affinity.enabled || cfg.websocket_actor.enabled {
		mut source_records := []map[string]string{}
		for source in cfg.websocket_actor.sources {
			source_records << {
				'type':  source.typ
				'key':   source.key
				'class': source.class_name
			}
		}
		target.policies.concurrency['${scope}_websocket'] = V2ConcurrencyPolicySpec{
			queue_timeout_ms:  cfg.websocket_actor.queue_timeout_ms
			max_queue_per_key: cfg.websocket_actor.max_queue_per_key
			affinity_enabled:  cfg.websocket_affinity.enabled
			actor_enabled:     cfg.websocket_actor.enabled
			actor_fallback:    cfg.websocket_actor.fallback
			affinity_source:   cfg.websocket_affinity.source
			affinity_key:      cfg.websocket_affinity.key
			affinity_scope:    cfg.websocket_affinity.scope
			affinity_fallback: cfg.websocket_affinity.fallback
			events:            cfg.websocket_actor.events.clone()
			record_options:    {
				'sources': source_records
			}
		}
	}

	if cfg.feishu.bridge.enabled || cfg.feishu.bridge.ws_url != '' {
		target.relays['${scope}/bridge'] = V2RelaySpec{
			mode:    'agent'
			carrier: 'websocket'
			url:     cfg.feishu.bridge.ws_url
			node_id: cfg.feishu.bridge.client_id
			token:   cfg.feishu.bridge.token
			options: {
				'target_id': cfg.feishu.bridge.target_id
				'enabled':   cfg.feishu.bridge.enabled.str()
			}
		}
	}
	return order
}

fn v1_engine_spec(kind string, worker WorkerConfig, php PhpConfig, vjsx VjsxConfig, resources []string) V2EngineSpec {
	normalized_kind := match kind.trim_space() {
		'php', '' { 'php-worker' }
		else { kind.trim_space() }
	}

	return V2EngineSpec{
		kind:                   normalized_kind
		entry:                  if normalized_kind == 'vjsx' {
			vjsx.app_entry
		} else {
			php.worker_entry
		}
		app:                    php.app_entry
		binary:                 php.bin
		module_root:            vjsx.module_root
		build_root:             vjsx.build_root
		runtime_profile:        vjsx.runtime_profile
		pool_size:              worker.pool_size
		thread_count:           vjsx.thread_count
		queue_capacity:         worker.queue_capacity
		queue_timeout_ms:       worker.queue_timeout_ms
		read_timeout_ms:        worker.read_timeout_ms
		restart_backoff_ms:     worker.restart_backoff_ms
		restart_backoff_max_ms: worker.restart_backoff_max_ms
		max_requests:           if worker.max_requests > 0 {
			worker.max_requests
		} else {
			vjsx.max_requests
		}
		autostart:              worker.autostart
		stream_dispatch:        worker.stream_dispatch
		websocket_dispatch:     worker.websocket_dispatch
		enable_fs:              vjsx.enable_fs
		enable_process:         vjsx.enable_process
		enable_network:         vjsx.enable_network
		socket:                 worker.socket
		socket_prefix:          worker.socket_prefix
		sockets:                worker.sockets.clone()
		signature_root:         vjsx.signature_root
		signature_include:      vjsx.signature_include.clone()
		signature_exclude:      vjsx.signature_exclude.clone()
		resources:              resources.clone()
		env:                    worker.env.clone()
		args:                   php.args.clone()
		extensions:             php.extensions.clone()
		options:                {
			'worker_cmd':           worker.cmd
			'worker_socket':        worker.socket
			'worker_socket_prefix': worker.socket_prefix
		}
	}
}

fn compile_v1_route_egress(route RouteRuleConfig, cfg VhttpdConfig, scope string, order int, default_adapter_id string, listener_id string, site_id string, mut target V2Config) string {
	executor_name := route.executor.trim_space()
	if route.status != 0 || route.location != '' || route.body != '' {
		adapter_id := '${scope}/route_${order}_response'
		target.adapters[adapter_id] = V2AdapterSpec{
			kind:    'fixed-response'
			options: {
				'status':   route.status.str()
				'location': route.location
				'body':     route.body
			}
		}
		return 'adapter:${adapter_id}'
	}
	if executor_name == '' {
		return 'adapter:${default_adapter_id}'
	}
	if executor_name == cfg.executor.kind
		|| (executor_name == 'php-worker' && cfg.executor.kind == 'php')
		|| (executor_name == 'php' && cfg.executor.kind == 'php-worker') {
		return 'adapter:${default_adapter_id}'
	}
	if executor_name == 'static' {
		adapter_id := '${scope}/route_${order}_static'
		completed_pipeline := compile_v1_upload_completed_pipeline(route.on_completed, cfg, scope,
			order, listener_id, site_id, mut target)
		target.adapters[adapter_id] = V2AdapterSpec{
			kind:               'static'
			root:               if route.root != '' { route.root } else { cfg.site.document_root }
			completed_pipeline: completed_pipeline
			options:            {
				'legacy_upload_dir': route.upload_dir
			}
		}
		return 'adapter:${adapter_id}'
	}
	if executor_name == 'upload' {
		adapter_id := '${scope}/route_${order}_upload'
		completed_pipeline := compile_v1_upload_completed_pipeline(route.on_completed, cfg, scope,
			order, listener_id, site_id, mut target)
		target.adapters[adapter_id] = V2AdapterSpec{
			kind:               'upload'
			root:               route.upload_dir
			max_body_bytes:     route.max_body_bytes
			completed_pipeline: completed_pipeline
		}
		return 'adapter:${adapter_id}'
	}
	if executor_name == 'none' {
		return 'terminal:reject'
	}
	return 'adapter:${scope}/${safe_plan_id(executor_name)}'
}

fn compile_v1_upload_completed_pipeline(value string, cfg VhttpdConfig, scope string, order int, listener_id string, site_id string, mut target V2Config) string {
	raw := value.trim_space()
	if raw == '' {
		return ''
	}
	handler := if raw.starts_with('vjsx:') { raw.all_after('vjsx:').trim_space() } else { raw }
	transform_id := '${scope}/upload_completed_${order}'
	mut engine_ref := ''
	if '${scope}/vjsx' in target.engines {
		engine_ref = 'engine:${scope}/vjsx'
	} else if cfg.executor.kind == 'vjsx' {
		engine_ref = 'engine:${scope}/default'
	}
	target.transforms[transform_id] = V2TransformSpec{
		kind:    if raw.starts_with('vjsx:') { 'vjsx' } else { 'native' }
		engine:  engine_ref
		handler: handler
	}
	event_adapter_id := '${scope}/upload_event_${order}'
	target.adapters[event_adapter_id] = V2AdapterSpec{
		kind:  'event-ingress'
		topic: 'upload.completed'
	}
	pipeline_id := '${listener_id}/event_upload_${order}'
	target.pipelines << V2PipelineSpec{
		id:         pipeline_id
		group:      'site:${site_id}'
		ingress:    'adapter:${event_adapter_id}'
		transforms: ['transform:${transform_id}']
		egress:     'terminal:ack'
	}
	return 'pipeline:${pipeline_id}'
}

fn safe_plan_id(value string) string {
	trimmed := value.trim_space()
	if trimmed == '' {
		return 'default'
	}
	return trimmed.replace(':', '_').replace(' ', '_')
}

fn normalize_v1_assets_prefix(value string) string {
	mut prefix := value.trim_space()
	if prefix == '' {
		return '/assets'
	}
	if !prefix.starts_with('/') {
		prefix = '/${prefix}'
	}
	for prefix.len > 1 && prefix.ends_with('/') {
		prefix = prefix[..prefix.len - 1]
	}
	return prefix
}
