module main

import runtime_plan

fn test_admin_apps_snapshot_groups_apps_and_pipeline_flow() {
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
					'db/wordpress': runtime_plan.ResourcePlan{
						id:       'db/wordpress'
						category: 'db'
						kind:     'mysql'
					}
				}
				engines: {
					'wordpress/php': runtime_plan.EnginePlan{
						id:        'wordpress/php'
						kind:      'php-worker'
						resources: [runtime_plan.ResourceRef{ domain: .resource, id: 'db/wordpress' }]
					}
				}
				adapters: {
					'wordpress-worker': runtime_plan.AdapterPlan{
						id:     'wordpress-worker'
						kind:   'http-handler'
						engine: runtime_plan.ResourceRef{ domain: .engine, id: 'wordpress/php' }
					}
				}
				policies: {
					'cache/front-page': runtime_plan.PolicyPlan{
						id:       'cache/front-page'
						category: 'cache'
						kind:     'cache'
					}
				}
				pipelines: [
					runtime_plan.PipelinePlan{
						id:      'wordpress.front-page'
						group:   'wordpress.dynamic.worker'
						ingress: runtime_plan.ResourceRef{ domain: .listener, id: 'web' }
						match:   runtime_plan.MatchPlan{
							paths: ['/', '/index.php']
						}
						policies: [runtime_plan.ResourceRef{ domain: .policy, id: 'cache/front-page' }]
						egress:   runtime_plan.ResourceRef{ domain: .adapter, id: 'wordpress-worker' }
					},
				]
			}
		}
	}
	snapshot := app.admin_apps_snapshot()
	assert snapshot.counts['apps'] == 1
	assert snapshot.counts['listeners'] == 1
	assert snapshot.counts['pipelines'] == 1
	assert snapshot.apps[0].id == 'wordpress'
	assert snapshot.apps[0].kind == 'wordpress'
	assert snapshot.apps[0].listeners[0].port == 8080
	assert snapshot.apps[0].pipelines[0].flow == [
		'listener:web',
		'pipeline:wordpress.front-page',
		'policy:cache/front-page',
		'adapter:wordpress-worker',
		'engine:wordpress/php',
		'resource:db/wordpress',
	]
}
