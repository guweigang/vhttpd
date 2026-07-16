module runtime_plan

fn test_plan_replacement_keeps_unaffected_pipeline_available() {
	old := RuntimePlan{
		listeners: {
			'web': ListenerPlan{
				id:       'web'
				protocol: 'http'
				host:     '127.0.0.1'
				port:     8080
			}
		}
		engines:   {
			'app':   EnginePlan{
				id:   'app'
				kind: 'php-worker'
			}
			'admin': EnginePlan{
				id:   'admin'
				kind: 'vjsx'
			}
		}
		adapters:  {
			'app':   AdapterPlan{
				id:     'app'
				kind:   'http-handler'
				engine: ResourceRef{
					domain: .engine
					id:     'app'
				}
			}
			'admin': AdapterPlan{
				id:     'admin'
				kind:   'http-handler'
				engine: ResourceRef{
					domain: .engine
					id:     'admin'
				}
			}
		}
		pipelines: [
			PipelinePlan{
				id:      'site/app'
				ingress: ResourceRef{
					domain: .listener
					id:     'web'
				}
				match:   MatchPlan{
					paths: ['*']
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'app'
				}
			},
			PipelinePlan{
				id:      'site/admin'
				ingress: ResourceRef{
					domain: .listener
					id:     'web'
				}
				match:   MatchPlan{
					paths: ['/admin']
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'admin'
				}
			},
		]
	}
	new := RuntimePlan{
		...old
		engines: {
			'app':   EnginePlan{
				id:      'app'
				kind:    'php-worker'
				options: PlanOptions{
					ints: {
						'queue_capacity': 128
					}
				}
			}
			'admin': old.engines['admin']
		}
	}

	diff := diff_runtime_plan_replacement(old, new)

	assert diff.allowed
	assert diff.drain_engines == ['app']
	assert diff.changed_pipelines == ['site/app']
	assert diff.unchanged_pipelines == ['site/admin']
}

fn test_plan_replacement_resource_change_affects_referencing_engine_pipeline() {
	old := RuntimePlan{
		resources: {
			'db/app': ResourcePlan{
				id:       'db/app'
				category: 'db'
				kind:     'mysql'
				options:  PlanOptions{
					strings: {
						'database': 'app'
					}
				}
			}
		}
		engines:   {
			'app': EnginePlan{
				id:        'app'
				kind:      'php-worker'
				resources: [ResourceRef{ domain: .resource, id: 'db/app' }]
			}
		}
		adapters:  {
			'app': AdapterPlan{
				id:     'app'
				kind:   'http-handler'
				engine: ResourceRef{
					domain: .engine
					id:     'app'
				}
			}
		}
		pipelines: [
			PipelinePlan{
				id:      'site/app'
				ingress: ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'app'
				}
			},
		]
	}
	new := RuntimePlan{
		...old
		resources: {
			'db/app': ResourcePlan{
				id:       'db/app'
				category: 'db'
				kind:     'mysql'
				options:  PlanOptions{
					strings: {
						'database': 'app_next'
					}
				}
			}
		}
	}

	diff := diff_runtime_plan_replacement(old, new)

	assert diff.allowed
	assert diff.changed_pipelines == ['site/app']
	assert diff.unchanged_pipelines.len == 0
}

fn test_plan_replacement_resource_string_list_order_is_significant() {
	old := RuntimePlan{
		resources: {
			'db/app': ResourcePlan{
				id:       'db/app'
				category: 'db'
				kind:     'mysql'
				options:  PlanOptions{
					string_lists: {
						'init_sql': ['SET a = 1', 'SET b = 2']
					}
				}
			}
		}
		engines:   {
			'app': EnginePlan{
				id:        'app'
				kind:      'php-worker'
				resources: [ResourceRef{ domain: .resource, id: 'db/app' }]
			}
		}
		adapters:  {
			'app': AdapterPlan{
				id:     'app'
				kind:   'http-handler'
				engine: ResourceRef{
					domain: .engine
					id:     'app'
				}
			}
		}
		pipelines: [
			PipelinePlan{
				id:      'site/app'
				ingress: ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'app'
				}
			},
		]
	}
	new := RuntimePlan{
		...old
		resources: {
			'db/app': ResourcePlan{
				...old.resources['db/app']
				options: PlanOptions{
					string_lists: {
						'init_sql': ['SET b = 2', 'SET a = 1']
					}
				}
			}
		}
	}

	diff := diff_runtime_plan_replacement(old, new)

	assert diff.changed_pipelines == ['site/app']
	assert diff.unchanged_pipelines.len == 0
}

fn test_plan_replacement_ignores_engine_resource_order() {
	old := RuntimePlan{
		resources: {
			'db/app':    ResourcePlan{
				id:       'db/app'
				category: 'db'
				kind:     'mysql'
			}
			'cache/app': ResourcePlan{
				id:       'cache/app'
				category: 'cache'
				kind:     'session-store'
			}
		}
		engines:   {
			'app': EnginePlan{
				id:        'app'
				kind:      'php-worker'
				resources: [
					ResourceRef{
						domain: .resource
						id:     'db/app'
					},
					ResourceRef{
						domain: .resource
						id:     'cache/app'
					},
				]
			}
		}
		adapters:  {
			'app': AdapterPlan{
				id:     'app'
				kind:   'http-handler'
				engine: ResourceRef{
					domain: .engine
					id:     'app'
				}
			}
		}
		pipelines: [
			PipelinePlan{
				id:      'site/app'
				ingress: ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'app'
				}
			},
		]
	}
	new := RuntimePlan{
		...old
		engines: {
			'app': EnginePlan{
				...old.engines['app']
				resources: [
					ResourceRef{
						domain: .resource
						id:     'cache/app'
					},
					ResourceRef{
						domain: .resource
						id:     'db/app'
					},
				]
			}
		}
	}

	diff := diff_runtime_plan_replacement(old, new)

	assert diff.allowed
	assert diff.drain_engines.len == 0
	assert diff.changed_pipelines.len == 0
	assert diff.unchanged_pipelines == ['site/app']
}

fn test_plan_replacement_engine_string_list_order_is_significant() {
	old := RuntimePlan{
		engines:   {
			'app': EnginePlan{
				id:      'app'
				kind:    'php-worker'
				options: PlanOptions{
					string_lists: {
						'extensions': ['/tmp/a.so', '/tmp/b.so']
					}
				}
			}
		}
		adapters:  {
			'app': AdapterPlan{
				id:     'app'
				kind:   'http-handler'
				engine: ResourceRef{
					domain: .engine
					id:     'app'
				}
			}
		}
		pipelines: [
			PipelinePlan{
				id:      'site/app'
				ingress: ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'app'
				}
			},
		]
	}
	new := RuntimePlan{
		...old
		engines: {
			'app': EnginePlan{
				...old.engines['app']
				options: PlanOptions{
					string_lists: {
						'extensions': ['/tmp/b.so', '/tmp/a.so']
					}
				}
			}
		}
	}

	diff := diff_runtime_plan_replacement(old, new)

	assert diff.drain_engines == ['app']
	assert diff.changed_pipelines == ['site/app']
	assert diff.unchanged_pipelines.len == 0
}

fn test_plan_replacement_rejects_unsafe_stateful_transform_switch() {
	old := RuntimePlan{
		transforms: {
			'rewrite': TransformPlan{
				id:      'rewrite'
				kind:    'vjsx'
				handler: 'rewrite.old'
				options: PlanOptions{
					bools: {
						'stateful': true
					}
				}
			}
		}
	}
	new := RuntimePlan{
		...old
		transforms: {
			'rewrite': TransformPlan{
				id:      'rewrite'
				kind:    'vjsx'
				handler: 'rewrite.new'
				options: PlanOptions{
					bools: {
						'stateful': true
					}
				}
			}
		}
	}

	diff := diff_runtime_plan_replacement(old, new)

	assert !diff.allowed
	assert diff.reload_transforms == ['rewrite']
	assert diff.reasons == [
		'stateful_transform_requires_external_state_or_migration:rewrite',
	]
}

fn test_plan_replacement_allows_stateful_transform_with_externalized_state() {
	old := RuntimePlan{
		transforms: {
			'rewrite': TransformPlan{
				id:      'rewrite'
				kind:    'vjsx'
				handler: 'rewrite.old'
				options: PlanOptions{
					bools: {
						'stateful': true
					}
				}
			}
		}
	}
	new := RuntimePlan{
		...old
		transforms: {
			'rewrite': TransformPlan{
				id:      'rewrite'
				kind:    'vjsx'
				handler: 'rewrite.new'
				options: PlanOptions{
					bools: {
						'stateful':           true
						'externalized_state': true
					}
				}
			}
		}
	}

	diff := diff_runtime_plan_replacement(old, new)

	assert diff.allowed
	assert diff.reload_transforms == ['rewrite']
	assert diff.reasons.len == 0
}

fn test_plan_replacement_provider_runtime_change_is_lightweight() {
	old := RuntimePlan{
		providers: {
			'feishu': ProviderPlan{
				id:     'feishu'
				driver: 'native'
			}
		}
	}
	new := RuntimePlan{
		providers: {
			'feishu': ProviderPlan{
				id:     'feishu'
				driver: 'vjsx'
				plugin: 'feishu_runtime'
			}
		}
	}

	diff := diff_runtime_plan_replacement(old, new)
	plan := execution_plan_for_replacement(diff)

	assert diff.allowed
	assert diff.reload_providers == ['feishu']
	assert plan.allowed
	assert plan.strategy == 'lightweight'
	assert plan.actions.len == 1
	assert plan.actions[0].kind == 'swap_lightweight_runtime'
	assert plan.actions[0].targets == ['feishu']
}

fn test_plan_replacement_provider_runtime_engine_change_does_not_drain_worker_engine() {
	old := RuntimePlan{
		engines:   {
			'feishu_runtime': EnginePlan{
				id:      'feishu_runtime'
				kind:    'vjsx'
				options: PlanOptions{
					strings: {
						'entry': 'providers/feishu-old.mts'
					}
				}
			}
		}
		providers: {
			'feishu': ProviderPlan{
				id:     'feishu'
				driver: 'vjsx'
				plugin: 'feishu_runtime'
				engine: ResourceRef{
					domain: .engine
					id:     'feishu_runtime'
				}
			}
		}
	}
	new := RuntimePlan{
		...old
		engines: {
			'feishu_runtime': EnginePlan{
				...old.engines['feishu_runtime']
				options: PlanOptions{
					strings: {
						'entry': 'providers/feishu-new.mts'
					}
				}
			}
		}
	}

	diff := diff_runtime_plan_replacement(old, new)
	plan := execution_plan_for_replacement(diff)

	assert diff.allowed
	assert diff.drain_engines.len == 0
	assert diff.reload_providers == ['feishu']
	assert plan.allowed
	assert plan.strategy == 'lightweight'
	assert plan.actions.len == 1
	assert plan.actions[0].kind == 'swap_lightweight_runtime'
	assert plan.actions[0].targets == ['feishu']
}

fn test_plan_replacement_transform_engine_change_reloads_transform_without_drain() {
	old := RuntimePlan{
		engines:    {
			'bridge_runtime': EnginePlan{
				id:      'bridge_runtime'
				kind:    'vjsx'
				options: PlanOptions{
					strings: {
						'entry': 'transforms/bridge-old.mts'
					}
				}
			}
		}
		transforms: {
			'bridge': TransformPlan{
				id:      'bridge'
				kind:    'vjsx'
				engine:  ResourceRef{
					domain: .engine
					id:     'bridge_runtime'
				}
				handler: 'bridge.transform'
			}
		}
	}
	new := RuntimePlan{
		...old
		engines: {
			'bridge_runtime': EnginePlan{
				...old.engines['bridge_runtime']
				options: PlanOptions{
					strings: {
						'entry': 'transforms/bridge-new.mts'
					}
				}
			}
		}
	}

	diff := diff_runtime_plan_replacement(old, new)
	plan := execution_plan_for_replacement(diff)

	assert diff.allowed
	assert diff.drain_engines.len == 0
	assert diff.reload_transforms == ['bridge']
	assert plan.allowed
	assert plan.strategy == 'lightweight'
	assert plan.actions.len == 1
	assert plan.actions[0].kind == 'swap_lightweight_runtime'
	assert plan.actions[0].targets == ['bridge']
}

fn test_plan_replacement_relay_change_requires_relay_reload() {
	old := RuntimePlan{
		relays: {
			'edge': RelayPlan{
				id:      'edge'
				mode:    'public'
				carrier: 'websocket'
				options: PlanOptions{
					strings: {
						'path': '/relay'
					}
				}
			}
		}
	}
	new := RuntimePlan{
		...old
		relays: {
			'edge': RelayPlan{
				...old.relays['edge']
				options: PlanOptions{
					strings: {
						'path': '/relay-next'
					}
				}
			}
		}
	}

	diff := diff_runtime_plan_replacement(old, new)
	plan := execution_plan_for_replacement(diff)

	assert diff.allowed
	assert diff.reload_relays == ['edge']
	assert !plan.allowed
	assert plan.strategy == 'relay_reload_required'
	assert plan.error == 'runtime_plan_replacement_requires_relay_reload'
	assert plan.actions.len == 1
	assert plan.actions[0].kind == 'reload_relays'
	assert plan.actions[0].targets == ['edge']
}

fn test_plan_replacement_relay_ingress_change_marks_pipeline_changed() {
	old := RuntimePlan{
		relays:    {
			'edge': RelayPlan{
				id:      'edge'
				mode:    'agent'
				carrier: 'websocket'
				options: PlanOptions{
					strings: {
						'url': 'ws://127.0.0.1:8080/relay'
					}
				}
			}
		}
		adapters:  {
			'response': AdapterPlan{
				id:   'response'
				kind: 'fixed-response'
			}
		}
		pipelines: [
			PipelinePlan{
				id:      'relay/local-response'
				ingress: ResourceRef{
					domain: .relay
					id:     'edge'
				}
				egress:  ResourceRef{
					domain: .adapter
					id:     'response'
				}
			},
		]
	}
	new := RuntimePlan{
		...old
		relays: {
			'edge': RelayPlan{
				...old.relays['edge']
				options: PlanOptions{
					strings: {
						'url': 'ws://127.0.0.1:9090/relay'
					}
				}
			}
		}
	}

	diff := diff_runtime_plan_replacement(old, new)

	assert diff.reload_relays == ['edge']
	assert diff.changed_pipelines == ['relay/local-response']
	assert diff.unchanged_pipelines.len == 0
}

fn test_plan_replacement_execution_plan_allows_lightweight_swap() {
	diff := PlanReplacementDiff{
		allowed:             true
		changed_pipelines:   ['site/hello']
		unchanged_pipelines: ['site/admin']
		reload_transforms:   ['rewrite']
	}

	plan := execution_plan_for_replacement(diff)

	assert plan.allowed
	assert plan.strategy == 'lightweight'
	assert plan.error == ''
	assert plan.actions.len == 1
	assert plan.actions[0].kind == 'swap_lightweight_runtime'
	assert plan.actions[0].targets == ['rewrite', 'site/hello']
	assert plan.diff.changed_pipelines == ['site/hello']
}

fn test_plan_replacement_execution_plan_rejects_engine_drain_for_now() {
	diff := PlanReplacementDiff{
		allowed:           true
		changed_pipelines: ['site/app']
		drain_engines:     ['app']
	}

	plan := execution_plan_for_replacement(diff)

	assert !plan.allowed
	assert plan.strategy == 'engine_drain_required'
	assert plan.error == 'runtime_plan_replacement_requires_engine_drain'
	assert plan.actions.len == 2
	assert plan.actions[0].kind == 'swap_lightweight_runtime'
	assert plan.actions[1].kind == 'drain_engines'
	assert plan.actions[1].targets == ['app']
}

fn test_plan_replacement_execution_plan_blocks_unsafe_transform() {
	diff := PlanReplacementDiff{
		allowed:           false
		changed_pipelines: ['site/app']
		reload_transforms: ['rewrite']
		reasons:           [
			'stateful_transform_requires_external_state_or_migration:rewrite',
		]
	}

	plan := execution_plan_for_replacement(diff)

	assert !plan.allowed
	assert plan.strategy == 'blocked'
	assert plan.error == 'runtime_plan_replacement_unsafe'
	assert plan.actions.len == 1
	assert plan.actions[0].kind == 'swap_lightweight_runtime'
	assert plan.diff.reasons == [
		'stateful_transform_requires_external_state_or_migration:rewrite',
	]
}
