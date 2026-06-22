module config

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
}
