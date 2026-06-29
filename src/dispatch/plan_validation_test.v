module dispatch

import runtime_plan

fn test_validate_runtime_plan_projection_reports_capability_issues_and_diagnostics() {
	plan := runtime_plan.RuntimePlan{
		listeners: {
			'web': runtime_plan.ListenerPlan{
				id:       'web'
				protocol: 'http'
			}
		}
		adapters:  {
			'ws': runtime_plan.AdapterPlan{
				id:   'ws'
				kind: 'websocket'
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'ws-on-http'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'ws'
				}
			},
		]
	}

	report := validate_runtime_plan_projection(plan)
	assert report.capability_issues.map(it.capability) == [
		'full_duplex',
		'sessions',
		'multiplexing',
	]
	assert report.diagnostics.len == 3
	assert report.diagnostics[0].severity == 'warning'
	assert report.diagnostics[0].code == 'pipeline_capability_mismatch'
	assert report.diagnostics[0].path == 'pipelines.ws-on-http'
	assert report.diagnostics[0].message == 'pipeline_capability_mismatch:ws-on-http:listener:web:full_duplex'
}

fn test_validate_runtime_plan_projection_reports_missing_references() {
	plan := runtime_plan.RuntimePlan{
		listeners: {
			'web': runtime_plan.ListenerPlan{
				id:       'web'
				protocol: 'http'
			}
		}
		adapters:  {
			'hello': runtime_plan.AdapterPlan{
				id:   'hello'
				kind: 'fixed-response'
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'missing-ingress'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'missing'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'hello'
				}
			},
			runtime_plan.PipelinePlan{
				id:         'missing-transform'
				ingress:    runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				transforms: [
					runtime_plan.ResourceRef{
						domain: .transform
						id:     'rewrite'
					},
				]
				egress:     runtime_plan.ResourceRef{
					domain: .adapter
					id:     'hello'
				}
			},
			runtime_plan.PipelinePlan{
				id:      'missing-egress'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'missing'
				}
			},
		]
	}

	diagnostics := runtime_plan_projection_diagnostics(plan)
	assert diagnostics.any(it.code == 'pipeline_projection_missing_ingress'
		&& it.path == 'pipelines.missing-ingress.ingress' && it.message.contains('listener:missing'))
	assert diagnostics.any(it.code == 'pipeline_projection_missing_transform'
		&& it.path == 'pipelines.missing-transform.transforms'
		&& it.message.contains('transform:rewrite'))
	assert diagnostics.any(it.code == 'pipeline_projection_missing_egress'
		&& it.path == 'pipelines.missing-egress.egress' && it.message.contains('adapter:missing'))
}

fn test_runtime_plan_projection_diagnostics_allows_event_ack_pipeline() {
	plan := runtime_plan.RuntimePlan{
		adapters:   {
			'upload_event': runtime_plan.AdapterPlan{
				id:   'upload_event'
				kind: 'event-ingress'
			}
		}
		transforms: {
			'upload_completed': runtime_plan.TransformPlan{
				id:      'upload_completed'
				kind:    'vjsx'
				handler: 'uploads.completed'
			}
		}
		pipelines:  [
			runtime_plan.PipelinePlan{
				id:         'event-upload'
				ingress:    runtime_plan.ResourceRef{
					domain: .adapter
					id:     'upload_event'
				}
				transforms: [
					runtime_plan.ResourceRef{
						domain: .transform
						id:     'upload_completed'
					},
				]
				egress:     runtime_plan.ResourceRef{
					domain: .terminal
					id:     'ack'
				}
			},
		]
	}

	assert runtime_plan_projection_diagnostics(plan).len == 0
}
