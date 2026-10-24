module runtime_plan

fn app_owner_query_plan() RuntimePlan {
	return RuntimePlan{
		listeners: {
			'relay': ListenerPlan{ id: 'relay', protocol: ' WebSocket ' }
			'a':     ListenerPlan{ id: 'a', protocol: 'http' }
			'b':     ListenerPlan{ id: 'b', protocol: 'http' }
			'solo':  ListenerPlan{ id: 'solo', protocol: 'websocket' }
		}
		relays:    {
			'edge': RelayPlan{ id: 'edge', ingress: ResourceRef{ domain: .listener, id: 'relay' } }
		}
		adapters:  {
			'delivery': AdapterPlan{
				id:      'delivery'
				kind:    'relay-delivery'
				options: PlanOptions{
					strings: {
						'target': 'relay:edge'
					}
				}
			}
		}
		pipelines: [
			PipelinePlan{ id: 'a', ingress: ResourceRef{ domain: .listener, id: 'a' }, egress: ResourceRef{ domain: .adapter, id: 'delivery' } },
			PipelinePlan{ id: 'b', ingress: ResourceRef{ domain: .listener, id: 'b' }, egress: ResourceRef{ domain: .adapter, id: 'delivery' } },
		]
	}
}

fn test_app_owner_is_stable_and_uses_only_available_listeners() {
	plan := app_owner_query_plan()
	assert plan.listener_app_owner_id('relay', ['relay', 'b', 'a']) == 'a'
	assert plan.listener_app_owner_id('relay', ['a', 'b', 'relay']) == 'a'
	assert plan.listener_app_owner_id('relay', ['b', 'relay']) == 'b'
	assert plan.listener_app_owner_id('relay', ['relay']) == 'relay'
}

fn test_independent_and_unknown_listeners_keep_their_own_app() {
	plan := app_owner_query_plan()
	for id in ['a', 'b', 'solo', 'missing'] {
		assert plan.listener_app_owner_id(id, ['relay', 'a', 'b', 'solo']) == id
	}
	assert plan.listener_app_owner_id('relay', []) == 'relay'
}

fn test_control_only_listener_borrows_the_unique_data_app_for_credential_ownership() {
	plan := RuntimePlan{
		listeners: {
			'control': ListenerPlan{ id: 'control', protocol: 'http' }
			'data':    ListenerPlan{ id: 'data', protocol: 'http' }
			'relay':   ListenerPlan{ id: 'relay', protocol: 'websocket' }
		}
		control:   ControlPlan{ listener: ResourceRef{ domain: .listener, id: 'control' } }
		pipelines: [PipelinePlan{ id: 'data', ingress: ResourceRef{ domain: .listener, id: 'data' } }]
	}
	assert plan.listener_app_owner_id('control', ['control', 'data']) == 'data'
	assert plan.listener_app_owner_id('control', ['data', 'relay', 'control', 'data']) == 'data'
	assert plan.listener_app_owner_id('control', ['control']) == 'control'
	assert plan.listener_app_owner_id('data', ['control', 'data']) == 'data'
}

fn test_control_owner_never_chooses_between_independent_data_apps_or_own_pipeline() {
	mut plan := RuntimePlan{
		listeners: {
			'control': ListenerPlan{ id: 'control', protocol: 'http' }
			'a':       ListenerPlan{ id: 'a', protocol: 'http' }
			'b':       ListenerPlan{ id: 'b', protocol: 'http' }
		}
		control:   ControlPlan{ listener: ResourceRef{ domain: .listener, id: 'control' } }
		pipelines: [
			PipelinePlan{ id: 'a', ingress: ResourceRef{ domain: .listener, id: 'a' } },
			PipelinePlan{ id: 'b', ingress: ResourceRef{ domain: .listener, id: 'b' } },
		]
	}
	assert plan.listener_app_owner_id('control', ['control', 'a', 'b']) == 'control'
	mut pipelines := plan.pipelines.clone()
	pipelines << PipelinePlan{ id: 'control', ingress: ResourceRef{ domain: .listener, id: 'control' } }
	with_pipeline := RuntimePlan{ ...plan, pipelines: pipelines }
	assert with_pipeline.listener_app_owner_id('control', ['control', 'a']) == 'control'
}
