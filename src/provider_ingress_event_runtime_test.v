module main

import runtime_plan

fn test_runtime_event_pipeline_selects_provider_ingress_by_metadata() {
	app := App{
		plan: runtime_plan.RuntimePlan{
			providers: {
				'feishu': runtime_plan.ProviderPlan{
					id: 'feishu'
				}
			}
			pipelines: [
				runtime_plan.PipelinePlan{
					id:      'provider.feishu.events'
					ingress: runtime_plan.ResourceRef{
						domain: .provider
						id:     'feishu'
					}
					match:   runtime_plan.MatchPlan{
						metadata: {
							'event':    'im.message.receive_v1'
							'instance': 'main'
						}
					}
					egress:  runtime_plan.ResourceRef{
						domain: .terminal
						id:     'ack'
					}
				},
			]
		}
	}

	pipeline := app.runtime_event_pipeline('provider:feishu', '', {
		'event':    'im.message.receive_v1'
		'instance': 'main'
	}) or { panic(err) }

	assert pipeline.id == 'provider.feishu.events'
}
