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
