module runtime_plan

fn test_resource_reference_round_trip() {
	for value in ['listener:public', 'resource:db/wordpress', 'engine:php',
		'adapter:assets', 'transform:rewrite', 'policy:cache/assets',
		'pipeline:upload_completed', 'relay:edge', 'terminal:ack'] {
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
				ingress: ResourceRef{domain: .listener, id: 'web'}
				egress:  ResourceRef{domain: .adapter, id: 'assets'}
			},
			PipelinePlan{
				id:      'application'
				ingress: ResourceRef{domain: .listener, id: 'web'}
				egress:  ResourceRef{domain: .adapter, id: 'php'}
			},
		]
	}
	assert plan.pipeline('assets')?.egress.str() == 'adapter:assets'
	assert plan.pipelines.map(it.id) == ['assets', 'application']
	assert plan.pipeline('missing') == none
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
				resources: [ResourceRef{domain: .resource, id: 'db/site'}]
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
				engine: ResourceRef{domain: .engine, id: 'site/default'}
			}
			'site/mcp':     AdapterPlan{
				id:   'site/mcp'
				kind: 'mcp'
			}
			'site/vjsx':    AdapterPlan{
				id:     'site/vjsx'
				kind:   'http-handler'
				engine: ResourceRef{domain: .engine, id: 'site/vjsx'}
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
				ingress: ResourceRef{domain: .listener, id: 'default'}
				egress:  ResourceRef{domain: .adapter, id: 'site/mcp'}
			},
			PipelinePlan{
				id:      'default/1_route'
				ingress: ResourceRef{domain: .listener, id: 'default'}
				egress:  ResourceRef{domain: .adapter, id: 'site/vjsx'}
			},
			PipelinePlan{
				id:      'default/2_fallback'
				ingress: ResourceRef{domain: .listener, id: 'default'}
				egress:  ResourceRef{domain: .adapter, id: 'site/default'}
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
