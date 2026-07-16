module relay

import runtime_plan

fn test_descriptor_from_hub_plan_requires_listener_and_sets_defaults() {
	relay_plan := runtime_plan.RelayPlan{
		id:      'edge'
		mode:    'hub'
		carrier: ''
		ingress: runtime_plan.ResourceRef{
			domain: .listener
			id:     'relay'
		}
		options: runtime_plan.PlanOptions{
			strings: {
				'path': '/vhttpd/relay'
			}
		}
	}

	descriptor := descriptor_from_plan(relay_plan) or { panic(err) }

	assert descriptor.id == 'edge'
	assert descriptor.mode == .hub
	assert descriptor.carrier == 'websocket'
	assert descriptor.listener?.str() == 'listener:relay'
	assert descriptor.node_id == 'edge'
	assert descriptor.path == '/vhttpd/relay'
	assert descriptor.max_channels == 1024
	assert descriptor.channel_buffer == 64
	assert descriptor.reconnect_delay_ms == 1000
}

fn test_descriptor_from_agent_plan_requires_url_and_preserves_limits() {
	relay_plan := runtime_plan.RelayPlan{
		id:      'local'
		mode:    'agent'
		carrier: 'websocket'
		options: runtime_plan.PlanOptions{
			strings: {
				'url':     'wss://relay.example.com/vhttpd/relay'
				'node_id': 'local-dev'
				'token':   'secret'
			}
			ints:    {
				'max_channels':       8
				'channel_buffer':     16
				'reconnect_delay_ms': 250
			}
		}
	}

	descriptor := descriptor_from_plan(relay_plan) or { panic(err) }

	assert descriptor.mode == .agent
	assert descriptor.url == 'wss://relay.example.com/vhttpd/relay'
	assert descriptor.node_id == 'local-dev'
	assert descriptor.token == 'secret'
	assert descriptor.max_channels == 8
	assert descriptor.channel_buffer == 16
	assert descriptor.reconnect_delay_ms == 250
}

fn test_descriptor_rejects_hub_without_listener() {
	descriptor_from_plan(runtime_plan.RelayPlan{
		id:   'edge'
		mode: 'hub'
	}) or {
		assert err.msg() == 'relay_descriptor_hub_missing_listener:edge'
		return
	}
	assert false
}

fn test_descriptor_rejects_agent_without_url() {
	descriptor_from_plan(runtime_plan.RelayPlan{
		id:   'local'
		mode: 'agent'
	}) or {
		assert err.msg() == 'relay_descriptor_agent_missing_url:local'
		return
	}
	assert false
}

fn test_descriptor_rejects_unsupported_mode_and_carrier() {
	descriptor_from_plan(runtime_plan.RelayPlan{
		id:   'edge'
		mode: 'proxy'
	}) or {
		assert err.msg() == 'relay_descriptor_unsupported_mode:proxy'
		return
	}
	assert false
}

fn test_descriptors_from_runtime_plan_are_sorted_and_indexed() {
	plan := runtime_plan.RuntimePlan{
		relays: {
			'local': runtime_plan.RelayPlan{
				id:      'local'
				mode:    'agent'
				carrier: 'websocket'
				options: runtime_plan.PlanOptions{
					strings: {
						'url': 'wss://relay.example.com'
					}
				}
			}
			'edge':  runtime_plan.RelayPlan{
				id:      'edge'
				mode:    'hub'
				carrier: 'websocket'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'relay'
				}
			}
		}
	}

	descriptors := descriptors_from_plan(plan) or { panic(err) }

	assert descriptors.len == 2
	assert descriptors['edge'].mode == .hub
	assert descriptors['local'].mode == .agent
}
