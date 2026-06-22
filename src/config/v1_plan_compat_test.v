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
		'default/0_route',
		'default/1_route',
		'default/2_route',
		'default/3_fallback',
	]
	assert plan.pipelines[0].egress.str() == 'adapter:wordpress/default'
	assert plan.pipelines[1].egress.str() == 'adapter:wordpress/php-cgi'
	assert plan.pipelines[2].egress.str() == 'adapter:wordpress/route_2_static'
	assert plan.pipelines[2].policies[0].str() == 'policy:cache/wordpress_route_2'
	assert plan.pipelines[3].egress.str() == 'adapter:wordpress/default'
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
	assert plan.pipeline('shop/0_fallback')?.group == 'site:shop'
	assert plan.pipeline('blog/0_fallback')?.egress.str() == 'adapter:blog/default'
}
