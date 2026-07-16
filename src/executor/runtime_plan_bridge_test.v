module executor

import config
import runtime_plan

fn test_runtime_plan_websocket_concurrency_policy_projects_to_executor_config() {
	plan := runtime_plan.RuntimePlan{
		listeners: {
			'web': runtime_plan.ListenerPlan{
				id:       'web'
				protocol: 'http'
			}
		}
		engines:   {
			'app':   runtime_plan.EnginePlan{
				id:   'app'
				kind: 'vjsx'
			}
			'other': runtime_plan.EnginePlan{
				id:   'other'
				kind: 'vjsx'
			}
		}
		adapters:  {
			'app':   runtime_plan.AdapterPlan{
				id:     'app'
				kind:   'http-handler'
				engine: runtime_plan.ResourceRef{
					domain: .engine
					id:     'app'
				}
			}
			'other': runtime_plan.AdapterPlan{
				id:     'other'
				kind:   'http-handler'
				engine: runtime_plan.ResourceRef{
					domain: .engine
					id:     'other'
				}
			}
		}
		policies:  {
			'concurrency/ws':    runtime_plan.PolicyPlan{
				id:       'concurrency/ws'
				category: 'concurrency'
				kind:     'concurrency'
				options:  runtime_plan.PlanOptions{
					strings:      {
						'affinity_source':   'query'
						'affinity_key':      'serverId'
						'affinity_scope':    'lane'
						'affinity_fallback': 'reject'
						'actor_fallback':    'unkeyed'
					}
					ints:         {
						'queue_timeout_ms':  30000
						'max_queue_per_key': 1024
					}
					bools:        {
						'affinity_enabled': false
						'actor_enabled':    true
					}
					string_lists: {
						'events': ['open', 'message', 'close']
					}
					record_lists: {
						'sources': [
							{
								'type': 'connection_cache'
							},
							{
								'type':  'query'
								'key':   'connectionId'
								'class': 'conn'
							},
							{
								'type': 'app'
							},
						]
					}
				}
			}
			'concurrency/other': runtime_plan.PolicyPlan{
				id:       'concurrency/other'
				category: 'concurrency'
				kind:     'concurrency'
				options:  runtime_plan.PlanOptions{
					strings: {
						'affinity_key': 'wrong'
					}
					bools:   {
						'affinity_enabled': true
					}
				}
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:       'web/ws'
				ingress:  runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				policies: [
					runtime_plan.ResourceRef{
						domain: .policy
						id:     'concurrency/ws'
					},
				]
				egress:   runtime_plan.ResourceRef{
					domain: .adapter
					id:     'app'
				}
			},
			runtime_plan.PipelinePlan{
				id:       'web/other'
				ingress:  runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				policies: [
					runtime_plan.ResourceRef{
						domain: .policy
						id:     'concurrency/other'
					},
				]
				egress:   runtime_plan.ResourceRef{
					domain: .adapter
					id:     'other'
				}
			},
		]
	}

	projected := vhttpd_config_with_websocket_dispatch_policy_from_plan(config.VhttpdConfig{},
		plan, 'web', 'app')

	assert !projected.websocket_affinity.enabled
	assert projected.websocket_affinity.source == 'query'
	assert projected.websocket_affinity.key == 'serverId'
	assert projected.websocket_affinity.scope == 'lane'
	assert projected.websocket_affinity.fallback == 'reject'
	assert projected.websocket_actor.enabled
	assert projected.websocket_actor.fallback == 'unkeyed'
	assert projected.websocket_actor.queue_timeout_ms == 30000
	assert projected.websocket_actor.max_queue_per_key == 1024
	assert projected.websocket_actor.events == ['open', 'message', 'close']
	assert projected.websocket_actor.sources.len == 3
	assert projected.websocket_actor.sources[0].typ == 'connection_cache'
	assert projected.websocket_actor.sources[1].key == 'connectionId'
	assert projected.websocket_actor.sources[1].class_name == 'conn'
	assert projected.websocket_actor.sources[2].typ == 'app'
}
