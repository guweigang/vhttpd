module config

import os

fn test_compile_v1_wordpress_shape_to_runtime_plan() {
	mut cfg := VhttpdConfig{}
	cfg.config_path = '/tmp/wordpress/vhttpd.toml'
	cfg.server.host = '127.0.0.1'
	cfg.server.port = 8080
	cfg.server.index = 'index.php'
	cfg.server.ssl = ServerSslConfig{
		enabled:  true
		cert:     'server.crt'
		cert_key: 'server.key'
	}
	cfg.site.name = 'wordpress'
	cfg.site.document_root = '/srv/wordpress'
	cfg.executor.kind = 'php'
	cfg.worker.pool_size = 4
	cfg.php.worker_entry = 'vendor/bin/vphp-worker'
	cfg.php.app_entry = 'app.php'
	cfg.db.enabled = true
	cfg.db.driver = 'mysql'
	cfg.db.mysql.database = 'wordpress'
	cfg.cache.enabled = true
	cfg.cache.socket = '/tmp/wordpress-cache.sock'
	cfg.executors['php-cgi'] = ExecutorSpecConfig{
		executor: ExecutorConfig{
			kind: 'php-cgi'
		}
		worker:   WorkerConfig{
			pool_size: 2
		}
		php:      PhpConfig{
			bin: 'php-cgi'
		}
	}
	cfg.routes = [
		RouteRuleConfig{
			match:    RouteMatchConfig{
				path: ['/index.php']
			}
			executor: 'php'
		},
		RouteRuleConfig{
			match:    RouteMatchConfig{
				path: ['/wp-admin/*']
			}
			executor: 'php-cgi'
		},
		RouteRuleConfig{
			match:                 RouteMatchConfig{
				path: ['/wp-content/*']
			}
			executor:              'static'
			root:                  '/srv/wordpress'
			cache_control:         'public, max-age=3600'
			response_cache_ttl_ms: 30000
		},
	]
	plan := compile_v1_runtime_plan(cfg) or { panic(err) }
	assert plan.source.compatibility
	assert plan.diagnostics[0].code == 'legacy_schema'
	assert plan.source.schema_version == 2
	assert plan.listeners['default'].tls.enabled
	assert plan.resources['db/wordpress'].kind == 'mysql'
	assert plan.resources['db/wordpress'].options.strings['pool_name'] == 'default'
	assert plan.resources['cache/wordpress'].options.strings['socket'] == '/tmp/wordpress-cache.sock'
	assert plan.engines['wordpress/default'].kind == 'php-worker'
	assert plan.engines['wordpress/default'].options.ints['pool_size'] == 4
	assert plan.engines['wordpress/php-cgi'].kind == 'php-cgi'
	assert plan.adapters['wordpress/default'].options.strings['document_root'] == '/srv/wordpress'
	assert plan.pipelines.map(it.id) == [
		'default/0_mcp',
		'default/1_route',
		'default/2_route',
		'default/3_route',
		'default/4_fallback',
	]
	assert plan.pipelines[0].egress.str() == 'adapter:wordpress/mcp'
	assert plan.pipelines[1].egress.str() == 'adapter:wordpress/default'
	assert plan.pipelines[2].egress.str() == 'adapter:wordpress/php-cgi'
	assert plan.pipelines[3].egress.str() == 'adapter:wordpress/route_3_static'
	assert plan.pipelines[3].policies[0].str() == 'policy:cache/wordpress_route_3'
	assert plan.pipelines[4].egress.str() == 'adapter:wordpress/default'
	assert plan.diagnostics.any(it.code == 'legacy_magic_executor'
		&& it.path == 'routes[2].executor')
}

fn test_compile_v1_multisite_preserves_listener_and_site_scopes() {
	mut cfg := VhttpdConfig{}
	cfg.sites = {
		'shop': SiteConfig{
			document_root: '/srv/shop'
			port:          8081
			executor:      ExecutorConfig{
				kind: 'php'
			}
			php:           PhpConfig{
				app_entry: 'shop.php'
			}
		}
		'blog': SiteConfig{
			document_root: '/srv/blog'
			port:          8082
			executor:      ExecutorConfig{
				kind: 'php'
			}
			php:           PhpConfig{
				app_entry: 'blog.php'
			}
		}
	}
	plan := compile_v1_runtime_plan(cfg) or { panic(err) }
	assert plan.listeners.keys().sorted() == ['blog', 'shop']
	assert plan.engines['shop/default'].options.strings['app'] == 'shop.php'
	assert plan.engines['blog/default'].options.strings['app'] == 'blog.php'
	assert plan.pipeline('shop/1_fallback')?.group == 'site:shop'
	assert plan.pipeline('blog/1_fallback')?.egress.str() == 'adapter:blog/default'
}

fn test_compile_v1_provider_plugin_websocket_and_bridge_resources() {
	mut cfg := VhttpdConfig{}
	cfg.site.name = 'gateway'
	cfg.openai.enabled = true
	cfg.openai.base_path = '/v1'
	cfg.openai.default_backend = 'main'
	cfg.openai.backends['main'] = OpenAIBackendConfig{
		base_url: 'https://api.example.com/v1'
		api_key:  'secret'
	}
	cfg.openai.routes['chat'] = OpenAIRouteConfig{
		models:         ['gpt-a', 'gpt-b']
		backend:        'main'
		upstream_model: 'gpt-upstream'
	}
	cfg.feishu.enabled = true
	cfg.feishu.apps['main'] = FeishuAppConfig{
		app_id:     'cli_a'
		app_secret: 'sec_a'
	}
	cfg.codex.enabled = true
	cfg.codex.model = 'gpt-5.4'
	cfg.plugins['planner'] = PluginConfig{
		entry:        'planner.mts'
		thread_count: 2
	}
	cfg.websocket_affinity = WebSocketAffinityConfig{
		enabled: true
		source:  'query'
		key:     'room'
		scope:   'global'
	}
	cfg.websocket_actor = WebSocketActorConfig{
		enabled: true
		sources: [
			WebSocketActorSourceConfig{
				typ:        'message_json'
				key:        'room'
				class_name: 'chat'
			},
		]
		events:  ['message']
	}
	cfg.feishu.bridge = BridgeConfig{
		enabled:   true
		ws_url:    'wss://relay.example.com'
		client_id: 'local'
		target_id: 'remote'
	}
	plan := compile_v1_runtime_plan(cfg) or { panic(err) }
	assert plan.adapters['gateway/mcp'].options.ints['max_sessions'] == 1000
	assert plan.adapters['gateway/openai'].options.record_lists['backends'][0]['id'] == 'main'
	assert plan.adapters['gateway/openai'].options.string_lists['chat'] == ['gpt-a', 'gpt-b']
	assert plan.adapters['gateway/feishu'].options.record_lists['apps'][0]['app_id'] == 'cli_a'
	assert plan.adapters['gateway/codex'].options.strings['model'] == 'gpt-5.4'
	assert plan.engines['gateway/plugin/planner'].options.strings['entry'] == 'planner.mts'
	assert plan.transforms['gateway/plugin/planner'].engine?.str() == 'engine:gateway/plugin/planner'
	assert plan.policies['concurrency/gateway_websocket'].options.record_lists['sources'][0]['class'] == 'chat'
	assert plan.relays['gateway/bridge'].options.strings['target_id'] == 'remote'
	assert plan.pipelines[0].id == 'default/0_mcp'
	assert plan.pipelines[1].id == 'default/1_openai'
}

fn test_runtime_plan_cli_overlay_updates_default_engine_only() {
	mut cfg := VhttpdConfig{}
	cfg.site.name = 'wordpress'
	cfg.executor.kind = 'php'
	cfg.worker.pool_size = 2
	cfg.worker.queue_capacity = 8
	cfg.php.worker_entry = 'worker.php'
	cfg.php.app_entry = 'app.php'
	cfg.executors['php-cgi'] = ExecutorSpecConfig{
		executor: ExecutorConfig{
			kind: 'php-cgi'
		}
		php:      PhpConfig{
			bin: 'php-cgi'
		}
	}
	cfg.routes = [
		RouteRuleConfig{
			match:    RouteMatchConfig{
				path: ['/wp-admin/*']
			}
			executor: 'php-cgi'
		},
	]
	plan := compile_v1_runtime_plan(cfg) or { panic(err) }
	resolved := runtime_plan_apply_cli_overrides([
		'--executor',
		'vjsx',
		'--vjsx-entry',
		'app.mts',
		'--vjsx-thread-count',
		'4',
		'--worker-queue-capacity',
		'64',
	], cfg, plan, 'default')

	assert resolved.engines['wordpress/default'].kind == 'vjsx'
	assert resolved.engines['wordpress/default'].options.strings['entry'] == 'app.mts'
	assert resolved.engines['wordpress/default'].options.ints['thread_count'] == 4
	assert resolved.engines['wordpress/default'].options.ints['queue_capacity'] == 64
	assert resolved.engines['wordpress/php-cgi'].kind == 'php-cgi'
	assert resolved.engines['wordpress/php-cgi'].options.strings['binary'] == 'php-cgi'
}

fn test_runtime_plan_cli_overlay_updates_provider_adapters() {
	mut cfg := VhttpdConfig{}
	cfg.site.name = 'gateway'
	cfg.feishu.enabled = false
	cfg.feishu.open_base_url = 'https://open.feishu.cn'
	cfg.feishu.apps['legacy'] = FeishuAppConfig{
		app_id:     'legacy_app'
		app_secret: 'legacy_secret'
	}
	cfg.codex.enabled = true
	plan := compile_v1_runtime_plan(cfg) or { panic(err) }
	resolved := runtime_plan_apply_cli_overrides([
		'--feishu-enabled',
		'1',
		'--feishu-open-base-url',
		'https://open.example.com',
		'--feishu-app-id',
		'cli_app',
		'--feishu-app-secret',
		'cli_secret',
		'--ollama-enabled',
		'1',
	], cfg, plan, 'default')

	feishu_adapter := resolved.adapters['gateway/feishu']
	assert feishu_adapter.options.bools['enabled']
	assert feishu_adapter.options.strings['open_base_url'] == 'https://open.example.com'
	assert feishu_adapter.options.record_lists['apps'].any(it['id'] == 'main'
		&& it['app_id'] == 'cli_app' && it['app_secret'] == 'cli_secret')
	assert resolved.adapters['gateway/codex'].options.bools['ollama_enabled']
}

fn test_compile_v1_upload_completion_and_response_headers_to_resources() {
	mut cfg := VhttpdConfig{}
	cfg.site.name = 'uploads'
	cfg.executors['vjsx'] = ExecutorSpecConfig{
		executor: ExecutorConfig{
			kind: 'vjsx'
		}
		vjsx:     VjsxConfig{
			app_entry: 'events.mts'
		}
	}
	cfg.routes = [
		RouteRuleConfig{
			match:            RouteMatchConfig{
				method: ['POST']
				path:   ['/uploads']
			}
			executor:         'upload'
			upload_dir:       '/tmp/uploads'
			on_completed:     'vjsx:uploads.completed'
			response_headers: {
				'x-content-type-options': 'nosniff'
			}
		},
	]
	plan := compile_v1_runtime_plan(cfg) or { panic(err) }
	assert plan.adapters['uploads/route_1_upload'].options.strings['completed_pipeline'] == 'pipeline:default/event_upload_1'
	assert plan.transforms['uploads/upload_completed_1'].handler == 'uploads.completed'
	assert plan.transforms['uploads/upload_completed_1'].engine?.str() == 'engine:uploads/vjsx'
	assert plan.pipeline('default/event_upload_1')?.ingress.str() == 'adapter:uploads/upload_event_1'
	assert plan.pipeline('default/1_route')?.policies[0].str() == 'policy:response/uploads_route_1'
	assert plan.policies['response/uploads_route_1'].options.string_maps['headers']['x-content-type-options'] == 'nosniff'
	assert plan.diagnostics.any(it.code == 'legacy_completion_handler')
}

fn test_representative_v1_and_v2_configs_compile_to_equivalent_http_plan() {
	mut legacy := VhttpdConfig{}
	legacy.server.host = '127.0.0.1'
	legacy.server.port = 8080
	legacy.site.name = 'wordpress'
	legacy.site.document_root = '/srv/wordpress'
	legacy.executor.kind = 'php'
	legacy.worker.pool_size = 4
	legacy.php.worker_entry = 'vendor/bin/vphp-worker'
	legacy.php.app_entry = 'app.php'
	legacy.db.enabled = true
	legacy.db.mysql.database = 'wordpress'
	legacy.routes = [
		RouteRuleConfig{
			match:         RouteMatchConfig{
				method: ['GET', 'HEAD']
				path:   ['/wp-content/*']
			}
			executor:      'static'
			root:          '/srv/wordpress'
			cache_control: 'public, max-age=3600'
		},
	]
	legacy_plan := compile_v1_runtime_plan(legacy) or { panic(err) }
	v2 := V2Config{
		listeners: {
			'default': V2ListenerSpec{
				protocol:  'http'
				transport: 'tcp'
				host:      '127.0.0.1'
				port:      8080
			}
		}
		resources: V2ResourceSpecs{
			db: {
				'wordpress': V2DbResourceSpec{
					kind:      'mysql'
					database:  'wordpress'
					pool_size: 5
				}
			}
		}
		engines:   {
			'wordpress/default': V2EngineSpec{
				kind:      'php-worker'
				entry:     'vendor/bin/vphp-worker'
				app:       'app.php'
				pool_size: 4
				resources: ['resource:db/wordpress']
			}
		}
		adapters:  {
			'wordpress/default':        V2AdapterSpec{
				kind:          'http-handler'
				engine:        'engine:wordpress/default'
				document_root: '/srv/wordpress'
				index:         'index.php'
			}
			'wordpress/mcp':            V2AdapterSpec{
				kind: 'mcp'
			}
			'wordpress/route_1_static': V2AdapterSpec{
				kind: 'static'
				root: '/srv/wordpress'
			}
		}
		policies:  V2PolicySpecs{
			cache: {
				'wordpress_route_1': V2CachePolicySpec{
					cache_control: 'public, max-age=3600'
				}
			}
		}
		pipelines: [
			V2PipelineSpec{
				id:      'default/0_mcp'
				ingress: 'listener:default'
				match:   V2MatchSpec{
					paths: ['/mcp']
				}
				egress:  'adapter:wordpress/mcp'
			},
			V2PipelineSpec{
				id:       'default/1_route'
				ingress:  'listener:default'
				match:    V2MatchSpec{
					methods: ['GET', 'HEAD']
					paths:   ['/wp-content/*']
				}
				policies: ['policy:cache/wordpress_route_1']
				egress:   'adapter:wordpress/route_1_static'
			},
			V2PipelineSpec{
				id:      'default/2_fallback'
				ingress: 'listener:default'
				match:   V2MatchSpec{
					paths: ['*']
				}
				egress:  'adapter:wordpress/default'
			},
		]
	}
	v2_plan := compile_v2_runtime_plan(v2, '', false) or { panic(err) }
	assert legacy_plan.listeners['default'] == v2_plan.listeners['default']
	assert legacy_plan.resources['db/wordpress'].kind == v2_plan.resources['db/wordpress'].kind
	assert legacy_plan.resources['db/wordpress'].options.strings['database'] == v2_plan.resources['db/wordpress'].options.strings['database']
	assert legacy_plan.engines['wordpress/default'].kind == v2_plan.engines['wordpress/default'].kind
	assert legacy_plan.engines['wordpress/default'].resources == v2_plan.engines['wordpress/default'].resources
	assert legacy_plan.adapters['wordpress/default'].kind == v2_plan.adapters['wordpress/default'].kind
	assert legacy_plan.adapters['wordpress/route_1_static'].options.strings['root'] == v2_plan.adapters['wordpress/route_1_static'].options.strings['root']
	assert legacy_plan.pipelines.map(it.id) == v2_plan.pipelines.map(it.id)
	assert legacy_plan.pipelines.map(it.egress.str()) == v2_plan.pipelines.map(it.egress.str())
	assert legacy_plan.pipelines[1].match.methods == v2_plan.pipelines[1].match.methods
	assert legacy_plan.pipelines[1].policies == v2_plan.pipelines[1].policies
}

fn test_repository_v1_examples_compile_to_resolved_plans() {
	repo_root := os.real_path(os.join_path(os.dir(@FILE), '..', '..'))
	wordpress_cfg := load_vhttpd_config(['--config',
		os.join_path(repo_root, 'examples', 'wordpress', 'vhttpd.toml')]) or { panic(err) }
	wordpress_plan := compile_v1_runtime_plan(wordpress_cfg) or { panic(err) }
	assert wordpress_plan.listeners['default'].tls.enabled
	assert wordpress_plan.engines['wordpress/php-cgi'].kind == 'php-cgi'
	mut upload_completion_found := false
	for _, transform in wordpress_plan.transforms {
		if transform.handler == 'wordpress.upload.completed' {
			upload_completion_found = transform.kind == 'vjsx'
				&& transform.engine?.str() == 'engine:wordpress/vjsx'
			break
		}
	}
	assert upload_completion_found
	mut rest_options_is_fixed := false
	for pipeline in wordpress_plan.pipelines {
		if pipeline.match.methods == ['OPTIONS'] && '/wp-json' in pipeline.match.paths {
			adapter := wordpress_plan.adapters[pipeline.egress.id]
			rest_options_is_fixed = adapter.kind == 'fixed-response'
				&& adapter.options.strings['status'] == '204'
			break
		}
	}
	assert rest_options_is_fixed

	openai_cfg := load_vhttpd_config(['--config',
		os.join_path(repo_root, 'examples', 'config', 'openai-gateway.toml')]) or { panic(err) }
	openai_plan := compile_v1_runtime_plan(openai_cfg) or { panic(err) }
	assert openai_plan.adapters['default/openai'].options.strings['default_backend'] == 'openai'
	assert openai_plan.transforms['default/plugin/openai_gateway'].engine?.str() == 'engine:default/plugin/openai_gateway'
	assert openai_plan.pipeline('default/1_openai')?.egress.str() == 'adapter:default/openai'
}
