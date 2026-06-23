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

fn test_compile_v2_runtime_plan_rejects_listener_without_pipeline() {
	cfg := V2Config{
		listeners: {
			'web': V2ListenerSpec{}
		}
	}
	if _ := compile_v2_runtime_plan(cfg, '', false) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_listener_without_pipeline:web'
	}
}

fn test_compile_v2_runtime_plan_allows_control_listener_without_pipeline() {
	cfg := V2Config{
		listeners: {
			'control': V2ListenerSpec{}
		}
		control:   V2ControlSpec{
			listener: 'listener:control'
		}
	}
	plan := compile_v2_runtime_plan(cfg, '', false) or { panic(err) }
	assert plan.control.listener?.str() == 'listener:control'
}

fn test_compile_v2_runtime_plan_allows_relay_listener_without_pipeline() {
	cfg := V2Config{
		listeners: {
			'relay': V2ListenerSpec{}
		}
		relays:    {
			'edge': V2RelaySpec{
				listener: 'listener:relay'
				carrier:  'websocket'
			}
		}
	}
	plan := compile_v2_runtime_plan(cfg, '', false) or { panic(err) }
	assert plan.relays['edge'].ingress?.str() == 'listener:relay'
}

fn test_compile_v2_runtime_plan_rejects_http_handler_without_engine() {
	cfg := V2Config{
		listeners: {
			'web': V2ListenerSpec{}
		}
		adapters:  {
			'app': V2AdapterSpec{
				kind: 'http-handler'
			}
		}
		pipelines: [
			V2PipelineSpec{
				id:      'site'
				ingress: 'listener:web'
				egress:  'adapter:app'
			},
		]
	}
	if _ := compile_v2_runtime_plan(cfg, '', false) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_adapter_missing_engine:app'
	}
}

fn test_compile_v2_runtime_plan_rejects_static_adapter_without_root_or_storage() {
	cfg := V2Config{
		listeners: {
			'web': V2ListenerSpec{}
		}
		adapters:  {
			'assets': V2AdapterSpec{
				kind: 'static'
			}
		}
		pipelines: [
			V2PipelineSpec{
				id:      'assets'
				ingress: 'listener:web'
				egress:  'adapter:assets'
			},
		]
	}
	if _ := compile_v2_runtime_plan(cfg, '', false) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_adapter_missing_storage:assets'
	}
}

fn test_compile_v2_runtime_plan_allows_static_adapter_with_storage_ref() {
	cfg := V2Config{
		listeners: {
			'web': V2ListenerSpec{}
		}
		resources: V2ResourceSpecs{
			storage: {
				'public': V2StorageResourceSpec{
					kind: 'filesystem'
					root: '/srv/public'
				}
			}
		}
		adapters:  {
			'assets': V2AdapterSpec{
				kind:    'static'
				storage: 'resource:storage/public'
			}
		}
		pipelines: [
			V2PipelineSpec{
				id:      'assets'
				ingress: 'listener:web'
				egress:  'adapter:assets'
			},
		]
	}
	plan := compile_v2_runtime_plan(cfg, '', false) or { panic(err) }
	assert plan.adapters['assets'].storage?.str() == 'resource:storage/public'
}

fn test_compile_v2_runtime_plan_rejects_empty_fixed_response_adapter() {
	cfg := V2Config{
		listeners: {
			'web': V2ListenerSpec{}
		}
		adapters:  {
			'empty': V2AdapterSpec{
				kind: 'fixed-response'
			}
		}
		pipelines: [
			V2PipelineSpec{
				id:      'empty'
				ingress: 'listener:web'
				egress:  'adapter:empty'
			},
		]
	}
	if _ := compile_v2_runtime_plan(cfg, '', false) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_adapter_empty_fixed_response:empty'
	}
}

fn test_compile_v2_runtime_plan_rejects_unknown_engine_kind() {
	cfg := V2Config{
		listeners: {
			'web': V2ListenerSpec{}
		}
		engines:   {
			'app': V2EngineSpec{
				kind:  'python'
				entry: 'app.py'
			}
		}
		adapters:  {
			'app': V2AdapterSpec{
				kind:   'http-handler'
				engine: 'engine:app'
			}
		}
		pipelines: [
			V2PipelineSpec{
				id:      'app'
				ingress: 'listener:web'
				egress:  'adapter:app'
			},
		]
	}
	if _ := compile_v2_runtime_plan(cfg, '', false) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_engine_unknown_kind:app:python'
	}
}

fn test_compile_v2_runtime_plan_rejects_engine_missing_entry() {
	cfg := V2Config{
		listeners: {
			'web': V2ListenerSpec{}
		}
		engines:   {
			'app': V2EngineSpec{
				kind: 'php-worker'
			}
		}
		adapters:  {
			'app': V2AdapterSpec{
				kind:   'http-handler'
				engine: 'engine:app'
			}
		}
		pipelines: [
			V2PipelineSpec{
				id:      'app'
				ingress: 'listener:web'
				egress:  'adapter:app'
			},
		]
	}
	if _ := compile_v2_runtime_plan(cfg, '', false) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_engine_missing_entry:app'
	}
}

fn test_compile_v2_runtime_plan_allows_compatibility_engine_missing_entry() {
	cfg := V2Config{
		listeners: {
			'web': V2ListenerSpec{}
		}
		engines:   {
			'app': V2EngineSpec{
				kind: 'php-worker'
			}
		}
		adapters:  {
			'app': V2AdapterSpec{
				kind:   'http-handler'
				engine: 'engine:app'
			}
		}
		pipelines: [
			V2PipelineSpec{
				id:      'app'
				ingress: 'listener:web'
				egress:  'adapter:app'
			},
		]
	}
	plan := compile_v2_runtime_plan(cfg, '', true) or { panic(err) }
	assert plan.source.compatibility
}

fn test_compile_v2_runtime_plan_rejects_unknown_transform_kind() {
	cfg := V2Config{
		listeners:  {
			'web': V2ListenerSpec{}
		}
		transforms: {
			'rewrite': V2TransformSpec{
				kind:    'lua'
				handler: 'rewrite'
			}
		}
		adapters:   {
			'app': V2AdapterSpec{
				kind:    'fixed-response'
				options: {
					'body': 'ok'
				}
			}
		}
		pipelines:  [
			V2PipelineSpec{
				id:         'app'
				ingress:    'listener:web'
				transforms: ['transform:rewrite']
				egress:     'adapter:app'
			},
		]
	}
	if _ := compile_v2_runtime_plan(cfg, '', false) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_transform_unknown_kind:rewrite:lua'
	}
}

fn test_compile_v2_runtime_plan_rejects_vjsx_transform_without_engine() {
	cfg := V2Config{
		listeners:  {
			'web': V2ListenerSpec{}
		}
		transforms: {
			'auth': V2TransformSpec{
				kind:    'vjsx'
				handler: 'auth.check'
			}
		}
		adapters:   {
			'app': V2AdapterSpec{
				kind:    'fixed-response'
				options: {
					'body': 'ok'
				}
			}
		}
		pipelines:  [
			V2PipelineSpec{
				id:         'app'
				ingress:    'listener:web'
				transforms: ['transform:auth']
				egress:     'adapter:app'
			},
		]
	}
	if _ := compile_v2_runtime_plan(cfg, '', false) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_transform_missing_engine:auth'
	}
}

fn test_compile_v2_runtime_plan_rejects_transform_missing_handler() {
	cfg := V2Config{
		listeners:  {
			'web': V2ListenerSpec{}
		}
		transforms: {
			'rewrite': V2TransformSpec{
				kind: 'native'
			}
		}
		adapters:   {
			'app': V2AdapterSpec{
				kind:    'fixed-response'
				options: {
					'body': 'ok'
				}
			}
		}
		pipelines:  [
			V2PipelineSpec{
				id:         'app'
				ingress:    'listener:web'
				transforms: ['transform:rewrite']
				egress:     'adapter:app'
			},
		]
	}
	if _ := compile_v2_runtime_plan(cfg, '', false) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_transform_missing_handler:rewrite'
	}
}
