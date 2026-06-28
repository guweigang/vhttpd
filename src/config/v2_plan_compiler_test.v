module config

import os
import toml

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

fn test_compile_v2_runtime_plan_preserves_relay_hub_path() {
	cfg := V2Config{
		listeners: {
			'relay': V2ListenerSpec{
				protocol: 'websocket'
			}
		}
		relays:    {
			'edge': V2RelaySpec{
				mode:      'hub'
				listener:  'listener:relay'
				carrier:   'websocket'
				path:      '/vhttpd/relay'
				node_id:   'hub_1'
				autostart: true
			}
		}
	}

	plan := compile_v2_runtime_plan(cfg, '', false) or { panic(err) }

	assert plan.relays['edge'].ingress?.str() == 'listener:relay'
	assert plan.relays['edge'].options.strings['path'] == '/vhttpd/relay'
	assert plan.relays['edge'].options.strings['node_id'] == 'hub_1'
	assert plan.relays['edge'].options.bools['autostart']
}

fn test_compile_v2_runtime_plan_loads_relay_hub_example() {
	config_path := os.join_path(os.dir(@FILE), '..', '..', 'examples', 'config',
		'relay-hub-v2.toml')
	text := os.read_file(config_path) or { panic(err) }
	cfg := toml.decode[V2Config](text) or { panic(err) }

	plan := compile_v2_runtime_plan(cfg, '', false) or { panic(err) }

	assert plan.listeners['relay'].protocol == 'websocket'
	assert plan.relays['edge'].ingress?.str() == 'listener:relay'
	assert plan.relays['edge'].options.strings['path'] == '/vhttpd/relay'
	assert plan.relays['edge'].options.strings['node_id'] == 'hub-local'
}

fn test_compile_v2_runtime_plan_loads_relay_agent_example() {
	config_path := os.join_path(os.dir(@FILE), '..', '..', 'examples', 'config',
		'relay-agent-v2.toml')
	text := os.read_file(config_path) or { panic(err) }
	cfg := toml.decode[V2Config](text) or { panic(err) }

	plan := compile_v2_runtime_plan(cfg, '', false) or { panic(err) }

	assert plan.relays['edge'].mode == 'agent'
	assert plan.relays['edge'].options.strings['url'] == 'ws://127.0.0.1:19921/vhttpd/relay'
	assert plan.relays['edge'].options.bools['autostart'] == false
	assert plan.pipeline('relay/local-response')?.ingress.str() == 'relay:edge'
	assert plan.pipeline('relay/local-response')?.egress.str() == 'adapter:local-response'
}

fn test_compile_v2_runtime_plan_loads_relay_agent_local_example() {
	config_path := os.join_path(os.dir(@FILE), '..', '..', 'examples', 'config',
		'relay-agent-local-v2.toml')
	text := os.read_file(config_path) or { panic(err) }
	cfg := toml.decode[V2Config](text) or { panic(err) }

	plan := compile_v2_runtime_plan(cfg, '', false) or { panic(err) }

	assert plan.relays['edge'].mode == 'agent'
	assert plan.relays['edge'].options.strings['url'] == 'ws://127.0.0.1:19921/vhttpd/relay'
	assert plan.relays['edge'].options.bools['autostart']
	assert plan.pipeline('relay/local-response')?.ingress.str() == 'relay:edge'
	assert plan.pipeline('relay/local-response')?.egress.str() == 'adapter:local-response'
}

fn test_compile_v2_runtime_plan_loads_relay_public_example() {
	config_path := os.join_path(os.dir(@FILE), '..', '..', 'examples', 'config',
		'relay-public-v2.toml')
	text := os.read_file(config_path) or { panic(err) }
	cfg := toml.decode[V2Config](text) or { panic(err) }

	plan := compile_v2_runtime_plan(cfg, '', false) or { panic(err) }

	assert plan.listeners['web'].protocol == 'http'
	assert plan.listeners['relay'].protocol == 'websocket'
	assert plan.relays['edge'].ingress?.str() == 'listener:relay'
	assert plan.adapters['relay-edge'].kind == 'relay-delivery'
	assert plan.adapters['relay-edge'].options.strings['target'] == 'relay:edge'
	assert plan.adapters['relay-edge'].options.strings['completion_mode'] == 'wait'
	assert plan.adapters['relay-edge'].options.ints['completion_timeout_ms'] == 30000
	assert plan.adapters['relay-edge'].options.strings['frame_kind'] == 'open'
	assert plan.adapters['relay-edge'].options.strings['route'] == 'relay/local-response'
	assert plan.pipeline('public/relay')?.ingress.str() == 'listener:web'
	assert plan.pipeline('public/relay')?.egress.str() == 'adapter:relay-edge'
	assert plan.relay_ids_for_listener('relay') == ['edge']
	assert plan.relay_delivery_owner_listener_ids('relay') == ['web']
}

fn test_compile_v2_runtime_plan_allows_relay_delivery_adapter() {
	cfg := V2Config{
		listeners: {
			'web': V2ListenerSpec{}
		}
		adapters:  {
			'relay': V2AdapterSpec{
				kind:        'relay-delivery'
				options:     {
					'target':          'relay:edge'
					'completion_mode': 'accepted'
					'frame_kind':      'open'
					'route':           'relay/local-response'
				}
				int_options: {
					'completion_timeout_ms': 1000
				}
			}
		}
		pipelines: [
			V2PipelineSpec{
				id:      'public/relay'
				ingress: 'listener:web'
				match:   V2MatchSpec{
					paths: ['/relay']
				}
				egress:  'adapter:relay'
			},
		]
		relays:    {
			'edge': V2RelaySpec{
				mode:    'hub'
				carrier: 'websocket'
			}
		}
	}

	plan := compile_v2_runtime_plan(cfg, '', false) or { panic(err) }

	assert plan.adapters['relay'].kind == 'relay-delivery'
	assert plan.adapters['relay'].options.strings['target'] == 'relay:edge'
	assert plan.adapters['relay'].options.strings['completion_mode'] == 'accepted'
	assert plan.adapters['relay'].options.strings['frame_kind'] == 'open'
	assert plan.adapters['relay'].options.strings['route'] == 'relay/local-response'
	assert plan.adapters['relay'].options.ints['completion_timeout_ms'] == 1000
	assert plan.pipeline('public/relay')?.egress.str() == 'adapter:relay'
}

fn test_compile_v2_runtime_plan_rejects_relay_delivery_adapter_without_target() {
	cfg := V2Config{
		listeners: {
			'web': V2ListenerSpec{}
		}
		adapters:  {
			'relay': V2AdapterSpec{
				kind: 'relay-delivery'
			}
		}
		pipelines: [
			V2PipelineSpec{
				id:      'public/relay'
				ingress: 'listener:web'
				egress:  'adapter:relay'
			},
		]
	}

	if _ := compile_v2_runtime_plan(cfg, '', false) {
		assert false
	} else {
		assert err.msg() == 'runtime_plan_adapter_missing_target:relay'
	}
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

fn test_compile_v2_runtime_plan_allows_compatibility_static_adapter_without_root() {
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
	plan := compile_v2_runtime_plan(cfg, '', true) or { panic(err) }
	assert plan.source.compatibility
	assert plan.adapters['assets'].kind == 'static'
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
