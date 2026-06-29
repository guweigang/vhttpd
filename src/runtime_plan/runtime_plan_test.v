module runtime_plan

fn test_resource_reference_round_trip() {
	for value in ['listener:public', 'resource:db/wordpress', 'engine:php', 'adapter:assets',
		'transform:rewrite', 'policy:cache/assets', 'pipeline:upload_completed', 'relay:edge',
		'terminal:ack'] {
		reference := parse_ref(value) or { panic(err) }
		assert reference.str() == value
	}
}

fn test_resource_reference_rejects_incomplete_values() {
	if _ := parse_ref('wordpress') {
		assert false
	} else {
		assert err.msg() == 'plan_ref_missing_domain:wordpress'
	}
	if _ := parse_ref('engine:') {
		assert false
	} else {
		assert err.msg() == 'plan_ref_missing_id:engine:'
	}
	if _ := parse_ref('site:wordpress') {
		assert false
	} else {
		assert err.msg() == 'plan_ref_unknown_domain:site'
	}
}

fn test_runtime_plan_preserves_pipeline_declaration_order() {
	plan := RuntimePlan{
		pipelines: [
			PipelinePlan{
				id:      'assets'
				ingress: ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'assets'
				}
			},
			PipelinePlan{
				id:      'application'
				ingress: ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'php'
				}
			},
		]
	}
	assert plan.pipeline('assets')?.egress.str() == 'adapter:assets'
	assert plan.pipelines.map(it.id) == ['assets', 'application']
	assert plan.pipeline('missing') == none
}

fn test_runtime_plan_listener_default_query_prefers_default_then_sorted() {
	default_plan := RuntimePlan{
		listeners: {
			'web':     ListenerPlan{
				id:   'web'
				port: 8080
			}
			'default': ListenerPlan{
				id:   'default'
				port: 18080
			}
		}
	}
	assert default_plan.first_listener_id_or_default() == 'default'
	assert default_plan.listener_or_default('')?.port == 18080

	sorted_plan := RuntimePlan{
		listeners: {
			'web_b': ListenerPlan{
				id:   'web_b'
				port: 8082
			}
			'web_a': ListenerPlan{
				id:   'web_a'
				port: 8081
			}
		}
	}
	assert sorted_plan.first_listener_id_or_default() == 'web_a'
	assert sorted_plan.listener_or_default('')?.port == 8081
}

fn test_plan_options_keep_kind_specific_values_typed() {
	resource := ResourcePlan{
		id:       'db/wordpress'
		category: 'db'
		kind:     'mysql'
		options:  PlanOptions{
			strings:      {
				'database': 'wordpress'
			}
			ints:         {
				'pool_size': 5
			}
			bools:        {
				'tls': false
			}
			string_lists: {
				'init_sql': ['SET NAMES utf8mb4']
			}
		}
	}
	assert resource.options.strings['database'] == 'wordpress'
	assert resource.options.ints['pool_size'] == 5
	assert resource.options.bools['tls'] == false
	assert resource.options.string_lists['init_sql'] == ['SET NAMES utf8mb4']
}

fn test_runtime_plan_listener_query_helpers() {
	plan := RuntimePlan{
		resources: {
			'db/site': ResourcePlan{
				id:       'db/site'
				category: 'db'
				kind:     'mysql'
			}
		}
		engines:   {
			'site/default': EnginePlan{
				id:        'site/default'
				kind:      'php-worker'
				resources: [ResourceRef{ domain: .resource, id: 'db/site' }]
			}
			'site/vjsx':    EnginePlan{
				id:   'site/vjsx'
				kind: 'vjsx'
			}
		}
		adapters:  {
			'site/default': AdapterPlan{
				id:     'site/default'
				kind:   'http-handler'
				engine: ResourceRef{
					domain: .engine
					id:     'site/default'
				}
			}
			'site/mcp':     AdapterPlan{
				id:   'site/mcp'
				kind: 'mcp'
			}
			'site/vjsx':    AdapterPlan{
				id:     'site/vjsx'
				kind:   'http-handler'
				engine: ResourceRef{
					domain: .engine
					id:     'site/vjsx'
				}
			}
			'site/codex':   AdapterPlan{
				id:   'site/codex'
				kind: 'codex'
			}
		}
		relays:    {
			'site/bridge': RelayPlan{
				id:      'site/bridge'
				carrier: 'websocket'
			}
		}
		pipelines: [
			PipelinePlan{
				id:      'default/0_mcp'
				ingress: ResourceRef{
					domain: .listener
					id:     'default'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'site/mcp'
				}
			},
			PipelinePlan{
				id:      'default/1_route'
				ingress: ResourceRef{
					domain: .listener
					id:     'default'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'site/vjsx'
				}
			},
			PipelinePlan{
				id:      'default/2_fallback'
				ingress: ResourceRef{
					domain: .listener
					id:     'default'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'site/default'
				}
			},
		]
	}

	assert listener_id_or_default('') == 'default'
	assert plan.listener_pipelines('').map(it.id) == ['default/0_mcp', 'default/1_route',
		'default/2_fallback']
	assert plan.listener_adapter('', 'mcp')?.id == 'site/mcp'
	assert plan.listener_fallback_engine('default')?.id == 'site/default'
	assert plan.listener_resource('', 'db')?.id == 'db/site'
	assert plan.listener_named_engine('', 'vjsx')?.id == 'site/vjsx'
	assert plan.first_adapter_by_kind('codex')?.id == 'site/codex'
	assert plan.first_relay_by_carrier('websocket')?.id == 'site/bridge'
}

fn test_runtime_plan_listener_named_engine_accepts_plain_engine_ids() {
	plan := RuntimePlan{
		engines:   {
			'php-cgi': EnginePlan{
				id:   'php-cgi'
				kind: 'php-cgi'
			}
		}
		adapters:  {
			'cgi': AdapterPlan{
				id:     'cgi'
				kind:   'http-handler'
				engine: ResourceRef{
					domain: .engine
					id:     'php-cgi'
				}
			}
		}
		pipelines: [
			PipelinePlan{
				id:      'admin'
				ingress: ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'cgi'
				}
			},
		]
	}

	engine := plan.listener_named_engine('web', 'php-cgi') or { panic('missing php-cgi engine') }
	assert engine.id == 'php-cgi'
}

fn test_runtime_plan_listener_fallback_engine_uses_first_http_handler_when_no_named_fallback() {
	plan := RuntimePlan{
		engines:   {
			'site/vjsx': EnginePlan{
				id:      'site/vjsx'
				kind:    'vjsx'
				options: PlanOptions{
					ints: {
						'read_timeout_ms': 1234
					}
				}
			}
		}
		adapters:  {
			'site/app': AdapterPlan{
				id:     'site/app'
				kind:   'http-handler'
				engine: ResourceRef{
					domain: .engine
					id:     'site/vjsx'
				}
			}
		}
		pipelines: [
			PipelinePlan{
				id:      'site'
				ingress: ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'site/app'
				}
			},
		]
	}

	engine := plan.listener_fallback_engine('web') or { panic('missing engine') }
	assert engine.id == 'site/vjsx'
	assert engine.options.ints['read_timeout_ms'] == 1234
}

fn test_runtime_plan_listener_fallback_engine_prefers_non_cgi_handler() {
	plan := RuntimePlan{
		engines:   {
			'php-cgi': EnginePlan{
				id:   'php-cgi'
				kind: 'php-cgi'
			}
			'php':     EnginePlan{
				id:   'php'
				kind: 'php-worker'
			}
		}
		adapters:  {
			'cgi':    AdapterPlan{
				id:     'cgi'
				kind:   'http-handler'
				engine: ResourceRef{
					domain: .engine
					id:     'php-cgi'
				}
			}
			'worker': AdapterPlan{
				id:     'worker'
				kind:   'http-handler'
				engine: ResourceRef{
					domain: .engine
					id:     'php'
				}
			}
		}
		pipelines: [
			PipelinePlan{
				id:      'compat'
				ingress: ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'cgi'
				}
			},
			PipelinePlan{
				id:      'front'
				ingress: ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'worker'
				}
			},
		]
	}

	engine := plan.listener_fallback_engine('web') or { panic('missing fallback engine') }
	assert engine.id == 'php'
}

fn test_runtime_plan_relay_pipeline_query_preserves_declaration_order() {
	plan := RuntimePlan{
		pipelines: [
			PipelinePlan{
				id:      'edge/local/open'
				ingress: ResourceRef{
					domain: .relay
					id:     'edge'
				}
				egress:  ResourceRef{
					domain: .terminal
					id:     'response'
				}
			},
			PipelinePlan{
				id:      'web'
				ingress: ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'app'
				}
			},
			PipelinePlan{
				id:      'edge/local/message'
				ingress: ResourceRef{
					domain: .relay
					id:     'edge'
				}
				egress:  ResourceRef{
					domain: .terminal
					id:     'response'
				}
			},
		]
	}

	assert plan.relay_pipelines('edge').map(it.id) == ['edge/local/open', 'edge/local/message']
	assert plan.relay_pipelines('missing').len == 0
}

fn test_runtime_plan_relay_delivery_owner_queries_match_by_relay_target() {
	plan := RuntimePlan{
		listeners: {
			'web_a':   ListenerPlan{
				id:       'web_a'
				protocol: 'http'
			}
			'web_b':   ListenerPlan{
				id:       'web_b'
				protocol: 'http'
			}
			'relay_a': ListenerPlan{
				id:       'relay_a'
				protocol: 'websocket'
			}
			'relay_b': ListenerPlan{
				id:       'relay_b'
				protocol: 'websocket'
			}
		}
		relays:    {
			'edge_a': RelayPlan{
				id:      'edge_a'
				mode:    'hub'
				carrier: 'websocket'
				ingress: ResourceRef{
					domain: .listener
					id:     'relay_a'
				}
			}
			'edge_b': RelayPlan{
				id:      'edge_b'
				mode:    'hub'
				carrier: 'websocket'
				ingress: ResourceRef{
					domain: .listener
					id:     'relay_b'
				}
			}
		}
		adapters:  {
			'relay_a': AdapterPlan{
				id:      'relay_a'
				kind:    'relay-delivery'
				options: PlanOptions{
					strings: {
						'target': 'relay:edge_a'
					}
				}
			}
			'relay_b': AdapterPlan{
				id:      'relay_b'
				kind:    'relay-delivery'
				options: PlanOptions{
					strings: {
						'target': 'relay:edge_b'
					}
				}
			}
		}
		pipelines: [
			PipelinePlan{
				id:      'web_a/relay'
				ingress: ResourceRef{
					domain: .listener
					id:     'web_a'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'relay_a'
				}
			},
			PipelinePlan{
				id:      'web_b/relay'
				ingress: ResourceRef{
					domain: .listener
					id:     'web_b'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'relay_b'
				}
			},
		]
	}

	assert plan.relay_ids_for_listener('relay_a') == ['edge_a']
	assert plan.listener_has_relay_delivery_target('web_a', 'edge_a')
	assert !plan.listener_has_relay_delivery_target('web_a', 'edge_b')
	assert plan.relay_delivery_owner_listener_ids('relay_a') == ['web_a']
	assert plan.relay_delivery_owner_listener_ids('relay_b') == ['web_b']
}
