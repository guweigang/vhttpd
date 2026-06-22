module config

fn test_compile_v2_runtime_plan_resolves_references_and_options() {
	cfg := V2Config{
		listeners: {
			'web': V2ListenerSpec{
				protocol:  'http'
				transport: 'tcp'
				host:      '127.0.0.1'
				port:      8080
			}
		}
		resources: V2ResourceSpecs{
			db: {
				'app': V2DbResourceSpec{
					kind:      'mysql'
					database:  'app'
					pool_size: 4
				}
			}
		}
		engines:   {
			'php': V2EngineSpec{
				kind:      'php-worker'
				entry:     'vendor/bin/vphp-worker'
				resources: ['resource:db/app']
			}
		}
		adapters:  {
			'app': V2AdapterSpec{
				kind:   'http-handler'
				engine: 'engine:php'
			}
		}
		policies:  V2PolicySpecs{
			limits: {
				'body': V2LimitPolicySpec{
					max_body_bytes: 1024
				}
			}
		}
		pipelines: [
			V2PipelineSpec{
				id:       'app'
				ingress:  'listener:web'
				match:    V2MatchSpec{
					paths: ['*']
				}
				policies: ['policy:limits/body']
				egress:   'adapter:app'
			},
		]
	}
	plan := compile_v2_runtime_plan(cfg, '/tmp/vhttpd.toml', false) or { panic(err) }
	assert !plan.source.compatibility
	assert plan.listeners['web'].port == 8080
	assert plan.resources['db/app'].options.strings['database'] == 'app'
	assert plan.resources['db/app'].options.ints['pool_size'] == 4
	assert plan.engines['php'].resources[0].str() == 'resource:db/app'
	assert plan.adapters['app'].engine?.str() == 'engine:php'
	assert plan.pipelines[0].policies[0].str() == 'policy:limits/body'
}

fn test_compile_v2_runtime_plan_rejects_unresolved_reference() {
	cfg := V2Config{
		listeners: {
			'web': V2ListenerSpec{}
		}
		pipelines: [
			V2PipelineSpec{
				id:      'broken'
				ingress: 'listener:web'
				egress:  'adapter:missing'
			},
		]
	}
	if _ := compile_v2_runtime_plan(cfg, '', false) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_unresolved_ref:adapter:missing'
	}
}

fn test_compile_v2_runtime_plan_rejects_wrong_reference_domain() {
	cfg := V2Config{
		engines: {
			'php': V2EngineSpec{
				resources: ['adapter:not-a-resource']
			}
		}
	}
	if _ := compile_v2_runtime_plan(cfg, '', false) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_ref_domain:adapter:not-a-resource:expected_resource'
	}
}
