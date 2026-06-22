module config

import runtime_plan

pub fn compile_v1_runtime_plan(cfg VhttpdConfig) !runtime_plan.RuntimePlan {
	v2 := compile_v1_to_v2(cfg)!
	return compile_v2_runtime_plan(v2, cfg.config_path, true)
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
			return error('v1_plan_unknown_listener_site:${listener_id}:${site_id}')
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

fn v1_listener_spec(host string, port int, ssl ServerSslConfig) V2ListenerSpec {
	return V2ListenerSpec{
		protocol:  'http'
		transport: 'tcp'
		host:      host
		port:      port
		tls:       V2TlsSpec{
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
	mut order := 0
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
		egress := compile_v1_route_egress(route, cfg, scope, order, default_adapter_id, mut target)
		target.pipelines << V2PipelineSpec{
			id:         pipeline_id
			group:      'site:${site_id}'
			ingress:    'listener:${listener_id}'
			match:      V2MatchSpec{
				methods:     route.match.method.clone()
				paths:       route.match.path.clone()
				path_regexp: route.match.path_regexp
				query:       route.match.query.clone()
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

fn compile_v1_route_egress(route RouteRuleConfig, cfg VhttpdConfig, scope string, order int, default_adapter_id string, mut target V2Config) string {
	executor_name := route.executor.trim_space()
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
		target.adapters[adapter_id] = V2AdapterSpec{
			kind: 'static'
			root: if route.root != '' { route.root } else { cfg.site.document_root }
		}
		return 'adapter:${adapter_id}'
	}
	if executor_name == 'upload' {
		adapter_id := '${scope}/route_${order}_upload'
		target.adapters[adapter_id] = V2AdapterSpec{
			kind:               'upload'
			root:               route.upload_dir
			max_body_bytes:     route.max_body_bytes
			completed_pipeline: route.on_completed
		}
		return 'adapter:${adapter_id}'
	}
	if executor_name == 'none' {
		if route.status == 0 && route.location == '' && route.body == '' {
			return 'terminal:reject'
		}
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
	return 'adapter:${scope}/${safe_plan_id(executor_name)}'
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
