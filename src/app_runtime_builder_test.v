module main

import config
import executor
import json
import os
import provider
import runtime_plan
import server_lifecycle

fn test_runtime_plan_with_projection_diagnostics_appends_to_runtime_visible_plan() {
	plan := runtime_plan.RuntimePlan{
		diagnostics: [
			runtime_plan.PlanDiagnostic{
				severity: 'info'
				code:     'compiled'
				path:     'source'
				message:  'compiled'
			},
		]
		listeners:   {
			'web': runtime_plan.ListenerPlan{
				id:       'web'
				protocol: 'http'
			}
		}
		adapters:    {
			'ws': runtime_plan.AdapterPlan{
				id:   'ws'
				kind: 'websocket'
			}
		}
		pipelines:   [
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

	runtime_visible_plan := runtime_plan_with_projection_diagnostics(plan)
	assert runtime_visible_plan.diagnostics.len == 4
	assert runtime_visible_plan.diagnostics[0].code == 'compiled'
	assert runtime_visible_plan.diagnostics[1].code == 'pipeline_capability_mismatch'
	assert runtime_visible_plan.diagnostics[1].path == 'pipelines.ws-on-http'

	encoded := json.encode(runtime_visible_plan)
	assert encoded.contains('"diagnostics"')
	assert encoded.contains('"pipeline_capability_mismatch"')
	assert encoded.contains('"pipelines.ws-on-http"')
}

fn test_runtime_plan_with_projection_diagnostics_is_idempotent() {
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

	once := runtime_plan_with_projection_diagnostics(plan)
	twice := runtime_plan_with_projection_diagnostics(once)

	assert once.diagnostics.len == 3
	assert twice.diagnostics.len == once.diagnostics.len
	assert twice.diagnostics.map(it.message) == once.diagnostics.map(it.message)
}

fn test_build_engine_runtime_from_v2_plan_keeps_plain_named_additional_engines() {
	repo_root := os.real_path(os.join_path(os.dir(@FILE), '..'))
	config_file := os.join_path(repo_root, 'examples', 'wordpress', 'vhttpd-v2.toml')
	plan := config.load_runtime_plan_file(config_file) or { panic(err) }
	routes := runtime_routes_from_plan(plan, 'web')
	cfg := config.default_vhttpd_config()
	executor_plan := executor.LogicExecutorRuntimePlan.resolve_from_plan([]string{}, cfg, plan,
		'web') or { panic(err) }

	engine_runtime := build_engine_runtime_with_diagnostics_from_plan(cfg, executor_plan, plan,
		'web', routes, server_lifecycle.AppRuntimeBuildConfig{
		plan_listener_id: 'web'
		workdir:          repo_root
	}).runtime

	cgi := engine_runtime.additional['php-cgi'] or { panic('missing php-cgi worker') }
	assert cgi.logic_executor.kind() == 'php-cgi'
	assert cgi.worker_backend.cmd.contains('php-cgi')
	assert cgi.worker_backend.sockets.len > 0
}

fn test_build_engine_runtime_records_additional_engine_diagnostics() {
	plan := runtime_plan.RuntimePlan{
		listeners: {
			'web': runtime_plan.ListenerPlan{
				id:       'web'
				protocol: 'http'
			}
		}
		engines:   {
			'app':    runtime_plan.EnginePlan{
				id:   'app'
				kind: 'php-worker'
			}
			'broken': runtime_plan.EnginePlan{
				id:   'broken'
				kind: 'not-a-real-executor'
			}
		}
		adapters:  {
			'app':    runtime_plan.AdapterPlan{
				id:     'app'
				kind:   'http-handler'
				engine: runtime_plan.ResourceRef{
					domain: .engine
					id:     'app'
				}
			}
			'broken': runtime_plan.AdapterPlan{
				id:     'broken'
				kind:   'http-handler'
				engine: runtime_plan.ResourceRef{
					domain: .engine
					id:     'broken'
				}
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'site/app'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'app'
				}
			},
			runtime_plan.PipelinePlan{
				id:      'site/broken'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'broken'
				}
			},
		]
	}
	cfg := config.default_vhttpd_config()
	executor_plan := executor.LogicExecutorRuntimePlan.resolve_from_plan([]string{}, cfg, plan,
		'web') or { panic(err) }
	routes := runtime_routes_from_plan(plan, 'web')

	result := build_engine_runtime_with_diagnostics_from_plan(cfg, executor_plan, plan, 'web',
		routes, server_lifecycle.AppRuntimeBuildConfig{})

	assert 'broken' !in result.runtime.additional
	assert result.diagnostics.len == 1
	assert result.diagnostics[0].severity == 'error'
	assert result.diagnostics[0].code == 'additional_engine_runtime_failed'
	assert result.diagnostics[0].path == 'engines.broken'
	assert result.diagnostics[0].message.contains('unsupported executor kind: not-a-real-executor')

	app := build_app_runtime(provider.ProviderRuntimeSettings{}, executor_plan, cfg, plan, server_lifecycle.AppRuntimeBuildConfig{
		plan_listener_id: 'web'
	})
	assert app.plan.diagnostics.any(it.code == 'additional_engine_runtime_failed'
		&& it.path == 'engines.broken')
	assert app.protocols.runtime_plan_json.contains('"additional_engine_runtime_failed"')
}

fn test_build_app_runtime_records_relay_runtime_diagnostics() {
	plan := runtime_plan.RuntimePlan{
		listeners: {
			'web': runtime_plan.ListenerPlan{
				id:       'web'
				protocol: 'http'
			}
		}
		engines:   {
			'app': runtime_plan.EnginePlan{
				id:   'app'
				kind: 'php-worker'
			}
		}
		adapters:  {
			'app': runtime_plan.AdapterPlan{
				id:     'app'
				kind:   'http-handler'
				engine: runtime_plan.ResourceRef{
					domain: .engine
					id:     'app'
				}
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'site/app'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'app'
				}
			},
		]
		relays:    {
			'bad': runtime_plan.RelayPlan{
				id:      'bad'
				mode:    'agent'
				options: runtime_plan.PlanOptions{
					strings: {
						'node_id': 'node-1'
					}
				}
			}
		}
	}
	relay_build := relay_runtime_with_diagnostics_from_plan(plan)
	assert relay_build.runtime.descriptors.len == 0
	assert relay_build.diagnostics.len == 1
	assert relay_build.diagnostics[0].code == 'relay_runtime_failed'
	assert relay_build.diagnostics[0].path == 'relays'
	assert relay_build.diagnostics[0].message.contains('relay_descriptor_agent_missing_url:bad')

	cfg := config.default_vhttpd_config()
	executor_plan := executor.LogicExecutorRuntimePlan.resolve_from_plan([]string{}, cfg, plan,
		'web') or { panic(err) }
	app := build_app_runtime(provider.ProviderRuntimeSettings{}, executor_plan, cfg, plan, server_lifecycle.AppRuntimeBuildConfig{
		plan_listener_id: 'web'
	})
	assert app.plan.diagnostics.any(it.code == 'relay_runtime_failed')
	assert app.protocols.runtime_plan_json.contains('"relay_runtime_failed"')
}

fn test_build_app_runtime_records_route_projection_diagnostics() {
	plan := runtime_plan.RuntimePlan{
		listeners: {
			'web': runtime_plan.ListenerPlan{
				id:       'web'
				protocol: 'http'
			}
		}
		adapters:  {
			'hello': runtime_plan.AdapterPlan{
				id:      'hello'
				kind:    'fixed-response'
				options: runtime_plan.PlanOptions{
					strings: {
						'status': '200'
						'body':   'ok'
					}
				}
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'site/bad-regexp'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				match:   runtime_plan.MatchPlan{
					path_regexp: '('
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'hello'
				}
			},
		]
	}
	cfg := config.default_vhttpd_config()
	executor_plan := executor.LogicExecutorRuntimePlan.resolve_from_plan([]string{}, cfg, plan,
		'web') or { panic(err) }
	app := build_app_runtime(provider.ProviderRuntimeSettings{}, executor_plan, cfg, plan, server_lifecycle.AppRuntimeBuildConfig{
		plan_listener_id: 'web'
	})

	assert app.pipelines.http.rules.len == 0
	assert app.plan.diagnostics.any(it.code == 'runtime_route_invalid_path_regexp'
		&& it.path == 'pipelines.site/bad-regexp.match.path_regexp')
	assert app.protocols.runtime_plan_json.contains('"runtime_route_invalid_path_regexp"')
}

fn test_build_app_runtime_records_missing_route_reference_diagnostics() {
	plan := runtime_plan.RuntimePlan{
		listeners: {
			'web': runtime_plan.ListenerPlan{
				id:       'web'
				protocol: 'http'
			}
		}
		adapters:  {
			'hello': runtime_plan.AdapterPlan{
				id:      'hello'
				kind:    'fixed-response'
				options: runtime_plan.PlanOptions{
					strings: {
						'status': '200'
						'body':   'ok'
					}
				}
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:         'site/missing-refs'
				ingress:    runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				transforms: [
					runtime_plan.ResourceRef{
						domain: .transform
						id:     'missing-rewrite'
					},
				]
				policies:   [
					runtime_plan.ResourceRef{
						domain: .policy
						id:     'missing-cache'
					},
				]
				egress:     runtime_plan.ResourceRef{
					domain: .adapter
					id:     'hello'
				}
			},
		]
	}
	cfg := config.default_vhttpd_config()
	executor_plan := executor.LogicExecutorRuntimePlan.resolve_from_plan([]string{}, cfg, plan,
		'web') or { panic(err) }
	app := build_app_runtime(provider.ProviderRuntimeSettings{}, executor_plan, cfg, plan, server_lifecycle.AppRuntimeBuildConfig{
		plan_listener_id: 'web'
	})

	assert app.pipelines.http.rules.len == 1
	assert app.plan.diagnostics.any(it.code == 'runtime_route_missing_transform'
		&& it.path == 'pipelines.site/missing-refs.transforms'
		&& it.message.contains('transform:missing-rewrite'))
	assert app.plan.diagnostics.any(it.code == 'runtime_route_missing_policy'
		&& it.path == 'pipelines.site/missing-refs.policies'
		&& it.message.contains('policy:missing-cache'))
	assert app.protocols.runtime_plan_json.contains('"runtime_route_missing_transform"')
	assert app.protocols.runtime_plan_json.contains('"runtime_route_missing_policy"')
}

fn test_build_app_runtime_records_route_preflight_diagnostics() {
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
				id:      'site/missing-adapter'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'missing'
				}
			},
			runtime_plan.PipelinePlan{
				id:      'site/resource-egress'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .resource
					id:     'cache'
				}
			},
			runtime_plan.PipelinePlan{
				id:      'site/ws-adapter'
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
	cfg := config.default_vhttpd_config()
	executor_plan := executor.LogicExecutorRuntimePlan.resolve_from_plan([]string{}, cfg, plan,
		'web') or { panic(err) }
	app := build_app_runtime(provider.ProviderRuntimeSettings{}, executor_plan, cfg, plan, server_lifecycle.AppRuntimeBuildConfig{
		plan_listener_id: 'web'
	})

	assert app.pipelines.http.rules.len == 0
	assert app.plan.diagnostics.any(it.code == 'runtime_route_missing_adapter'
		&& it.path == 'pipelines.site/missing-adapter.egress'
		&& it.message.contains('adapter:missing'))
	assert app.plan.diagnostics.any(it.code == 'runtime_route_unsupported_egress'
		&& it.path == 'pipelines.site/resource-egress.egress'
		&& it.message.contains('resource:cache'))
	assert app.plan.diagnostics.any(it.code == 'runtime_route_unsupported_adapter'
		&& it.path == 'adapters.ws' && it.message.contains('websocket'))
	assert app.protocols.runtime_plan_json.contains('"runtime_route_missing_adapter"')
	assert app.protocols.runtime_plan_json.contains('"runtime_route_unsupported_egress"')
	assert app.protocols.runtime_plan_json.contains('"runtime_route_unsupported_adapter"')
}

fn test_build_app_runtime_records_openai_protocol_diagnostics() {
	plan := runtime_plan.RuntimePlan{
		listeners: {
			'web': runtime_plan.ListenerPlan{
				id:       'web'
				protocol: 'http'
			}
		}
		adapters:  {
			'openai': runtime_plan.AdapterPlan{
				id:      'openai'
				kind:    'openai'
				options: runtime_plan.PlanOptions{
					strings:      {
						'default_backend': 'missing-default'
					}
					record_lists: {
						'backends': [
							{
								'base_url': 'https://api.example.test/v1'
							},
						]
						'routes':   [
							{
								'model':   'gpt-test'
								'backend': 'missing-route-backend'
							},
							{
								'id':      'chat'
								'model':   'gpt-chat'
								'backend': 'missing-route-backend'
							},
						]
					}
				}
			}
		}
		pipelines: [
			runtime_plan.PipelinePlan{
				id:      'site/openai'
				ingress: runtime_plan.ResourceRef{
					domain: .listener
					id:     'web'
				}
				egress:  runtime_plan.ResourceRef{
					domain: .adapter
					id:     'openai'
				}
			},
		]
	}
	cfg := config.default_vhttpd_config()
	executor_plan := executor.LogicExecutorRuntimePlan.resolve_from_plan([]string{}, cfg, plan,
		'web') or { panic(err) }
	app := build_app_runtime(provider.ProviderRuntimeSettings{}, executor_plan, cfg, plan, server_lifecycle.AppRuntimeBuildConfig{
		plan_listener_id: 'web'
	})

	assert app.plan.diagnostics.any(it.code == 'openai_backend_missing_id'
		&& it.path == 'adapters.openai.options.backends')
	assert app.plan.diagnostics.any(it.code == 'openai_default_backend_missing'
		&& it.path == 'adapters.openai.options.default_backend'
		&& it.message.contains('missing-default'))
	assert app.plan.diagnostics.any(it.code == 'openai_route_missing_id'
		&& it.path == 'adapters.openai.options.routes')
	assert app.plan.diagnostics.any(it.code == 'openai_route_backend_missing'
		&& it.path == 'adapters.openai.options.routes.chat.backend'
		&& it.message.contains('missing-route-backend'))
	assert app.protocols.runtime_plan_json.contains('"openai_backend_missing_id"')
	assert app.protocols.runtime_plan_json.contains('"openai_default_backend_missing"')
	assert app.protocols.runtime_plan_json.contains('"openai_route_missing_id"')
	assert app.protocols.runtime_plan_json.contains('"openai_route_backend_missing"')
}
