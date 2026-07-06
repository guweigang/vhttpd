module main

import runtime_plan

fn test_admin_runtime_graph_projects_plan_dependencies() {
	app := App{
		DataPlaneRuntime: DataPlaneRuntime{
			plan: runtime_plan.RuntimePlan{
				listeners: {
					'web': runtime_plan.ListenerPlan{
						id:        'web'
						protocol:  'http'
						transport: 'tcp'
						host:      '127.0.0.1'
						port:      8080
					}
				}
				resources: {
					'db/app': runtime_plan.ResourcePlan{
						id:       'db/app'
						category: 'db'
						kind:     'mysql'
					}
					'storage/public': runtime_plan.ResourcePlan{
						id:       'storage/public'
						category: 'storage'
						kind:     'filesystem'
					}
				}
				engines: {
					'app': runtime_plan.EnginePlan{
						id:        'app'
						kind:      'vjsx'
						resources: [runtime_plan.ResourceRef{ domain: .resource, id: 'db/app' }]
					}
				}
				transforms: {
					'rewrite': runtime_plan.TransformPlan{
						id:      'rewrite'
						kind:    'vjsx'
						engine:  runtime_plan.ResourceRef{ domain: .engine, id: 'app' }
						handler: 'rewrite'
					}
				}
				adapters: {
					'app': runtime_plan.AdapterPlan{
						id:      'app'
						kind:    'http-handler'
						engine:  runtime_plan.ResourceRef{ domain: .engine, id: 'app' }
						storage: runtime_plan.ResourceRef{ domain: .resource, id: 'storage/public' }
					}
					'relay': runtime_plan.AdapterPlan{
						id:      'relay'
						kind:    'relay-delivery'
						options: runtime_plan.PlanOptions{
							strings: {
								'target': 'relay:edge'
								'route':  'relay/local'
							}
						}
					}
				}
				relays: {
					'edge': runtime_plan.RelayPlan{
						id:      'edge'
						mode:    'hub'
						carrier: 'websocket'
						ingress: runtime_plan.ResourceRef{ domain: .listener, id: 'web' }
					}
				}
				pipelines: [
					runtime_plan.PipelinePlan{
						id:         'web/app'
						group:      'site:app'
						ingress:    runtime_plan.ResourceRef{ domain: .listener, id: 'web' }
						transforms: [runtime_plan.ResourceRef{ domain: .transform, id: 'rewrite' }]
						egress:     runtime_plan.ResourceRef{ domain: .adapter, id: 'app' }
					},
					runtime_plan.PipelinePlan{
						id:      'public/relay'
						ingress: runtime_plan.ResourceRef{ domain: .listener, id: 'web' }
						egress:  runtime_plan.ResourceRef{ domain: .adapter, id: 'relay' }
					},
				]
			}
		}
	}
	graph := app.admin_runtime_graph_snapshot()
	refs := graph.nodes.map(it.ref)
	assert refs.contains('listener:web')
	assert refs.contains('pipeline:web/app')
	assert refs.contains('transform:rewrite')
	assert refs.contains('adapter:app')
	assert refs.contains('engine:app')
	assert refs.contains('resource:db/app')
	assert refs.contains('relay:edge')

	edge_ids := graph.edges.map(it.id)
	assert edge_ids.contains('ingress:listener:web->pipeline:web/app')
	assert edge_ids.contains('uses_transform:pipeline:web/app->transform:rewrite')
	assert edge_ids.contains('egress:pipeline:web/app->adapter:app')
	assert edge_ids.contains('adapter_uses_engine:adapter:app->engine:app')
	assert edge_ids.contains('adapter_uses_storage:adapter:app->resource:storage/public')
	assert edge_ids.contains('engine_uses_resource:engine:app->resource:db/app')
	assert edge_ids.contains('transform_uses_engine:transform:rewrite->engine:app')
	assert edge_ids.contains('relay_ingress:relay:edge->listener:web')
	assert edge_ids.contains('adapter_uses_relay:adapter:relay->relay:edge')
}
