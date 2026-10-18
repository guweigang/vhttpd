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
