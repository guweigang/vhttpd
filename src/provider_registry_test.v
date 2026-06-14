module main

import config
import provider
import feishu
import codex
import dbx
import upstream

fn test_provider_registry_smoke() {
	// Basic smoke assertions for provider registry API surface
	// provider spec creation via provider_specs_copy should compile (no global state mutation)
	mut app := App{}
	// calling provider_specs_copy on empty app should return empty list
	specs := app.provider_specs_copy()
	assert specs.len == 0
}

fn test_provider_register_and_snapshot() {
	mut app := App{}
	// register a dummy provider via app.register_provider if available
	p := FeishuProvider{}
	app.register_provider('feishu-test', p)

	// verify provider_names contains our registration
	names := app.provider_names()
	assert names.contains('feishu-test')

	// provider_specs_copy should contain an entry for the provider
	specs := app.provider_specs_copy()
	mut found := false
	for s in specs {
		if s.name == 'feishu-test' {
			found = true
			// route_kind is an enum; migration path sets .generic by default.
			assert s.enabled
		}
	}
	assert found

	// cleanup: remove spec directly from app for test isolation
	app.mu.@lock()
	app.providers.registry.specs.delete('feishu-test')
	app.mu.unlock()
	names2 := app.provider_names()
	assert !names2.contains('feishu-test')
}

fn test_provider_runtime_snapshots_expose_registered_runtime() {
	mut app := App{
		providers: ProviderRuntimeHub{
			registry: ProviderHost{
				specs: map[string]ProviderSpec{}
			}
		}
	}
	app.register_provider_spec(ProviderSpec{
		name:             'ollama'
		enabled:          true
		has_handler:      false
		has_runtime:      true
		command_matchers: []provider.CommandMatcher{}
		route_kind:       .ollama
		provider:         OllamaProvider{}
		handler:          provider.NoopProviderCommandHandler{}
		runtime:          NoopProviderRuntime{}
	})
	snapshots := app.admin_provider_runtimes_snapshot()
	assert snapshots.len == 1
	assert snapshots[0].name == 'ollama'
	assert snapshots[0].enabled
	assert snapshots[0].snapshot == '{}'
}

fn test_provider_enabled_and_runtime_snapshot_use_host() {
	mut app := App{
		providers: ProviderRuntimeHub{
			registry: ProviderHost{
				specs: map[string]ProviderSpec{}
			}
		}
	}
	app.register_provider_spec(ProviderSpec{
		name:             'test-provider'
		enabled:          true
		has_handler:      false
		has_runtime:      true
		command_matchers: []provider.CommandMatcher{}
		route_kind:       .generic
		provider:         CodexProvider{}
		handler:          provider.NoopProviderCommandHandler{}
		runtime:          NoopProviderRuntime{}
	})
	assert app.provider_enabled('test-provider')
	assert app.provider_runtime_snapshot('test-provider') or { '' } == '{}'
	assert !app.provider_enabled('missing')
}

fn test_provider_bootstrap_and_runtime_ready_helpers() {
	mut app := App{
		providers: ProviderRuntimeHub{
			feishu:   feishu.FeishuState{
				enabled: true
				apps:    {
					'main': config.FeishuAppConfig{
						app_id: 'test-app'
					}
				}
				runtime: {
					'main': feishu.ProviderRuntime{}
				}
			}
			codex:    codex.CodexState{
				ollama_enabled: true
			}
			registry: ProviderHost{
				specs: map[string]ProviderSpec{}
			}
		}
	}
	assert app.provider_bootstrap_enabled('feishu')
	assert app.provider_bootstrap_enabled('ollama')
	assert !app.provider_bootstrap_enabled('codex')
	assert !app.provider_bootstrap_enabled('db')
	assert app.provider_runtime_ready('feishu')
	assert app.provider_runtime_default_instance('feishu') == 'main'
	assert app.provider_runtime_instances('feishu') == ['main']
	assert app.provider_runtime_feishu_snapshot().apps.len == 1
	app_snapshot := app.provider_runtime_feishu_app_snapshot('main') or {
		feishu.RuntimeAppSnapshot{}
	}
	assert app_snapshot.name == 'main'
	assert app_snapshot.source == 'static'
	assert app_snapshot.static_configured
	assert !app_snapshot.dynamic_configured
	assert !app.provider_runtime_ready('codex')
}

fn test_provider_runtime_dynamic_feishu_instance_is_bootstrapped_and_ready() {
	mut app := App{
		providers: ProviderRuntimeHub{
			instances: provider.ProviderInstanceRegistry{
				specs: {
					'feishu/main': provider.ProviderInstanceSpec{
						provider:      'feishu'
						instance:      'main'
						config_json:   '{"app_id":"cli_main","app_secret":"cli_secret"}'
						desired_state: 'connected'
					}
				}
			}
			feishu:    feishu.FeishuState{
				apps:    map[string]config.FeishuAppConfig{}
				runtime: map[string]feishu.ProviderRuntime{}
			}
		}
	}
	spec := app.provider_instance_ensure('feishu', 'main') or { provider.ProviderInstanceSpec{} }
	assert spec.provider == 'feishu'
	assert app.provider_bootstrap_enabled('feishu')
	assert app.provider_runtime_ready('feishu')
	assert app.provider_runtime_default_instance('feishu') == 'main'
	assert app.provider_runtime_instances('feishu') == ['main']
	app_snapshot := app.provider_runtime_feishu_app_snapshot('main') or {
		feishu.RuntimeAppSnapshot{}
	}
	assert app_snapshot.source == 'dynamic'
	assert !app_snapshot.static_configured
	assert app_snapshot.dynamic_configured
}

fn test_provider_runtime_pull_url_and_reconnect_delay_helpers() {
	mut app := App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				reconnect_delay_ms: 4321
			}
			codex:  codex.CodexState{
				runtime: codex.ProviderRuntime{
					enabled:            true
					url:                'ws://codex.local/ws'
					reconnect_delay_ms: 9876
				}
			}
		}
	}
	assert app.provider_runtime_pull_url('codex', 'main') or { '' } == 'ws://codex.local/ws'
	assert app.provider_runtime_reconnect_delay_ms('codex', 'main') == 9876
	assert app.provider_runtime_reconnect_delay_ms('feishu', 'main') == 4321
}

fn test_provider_runtime_dynamic_codex_instance_is_bootstrapped_and_enabled() {
	mut app := App{
		providers: ProviderRuntimeHub{
			codex:     codex.CodexState{
				runtime: codex.ProviderRuntime{}
			}
			instances: provider.ProviderInstanceRegistry{
				specs: {
					'codex/main':         provider.ProviderInstanceSpec{
						provider:      'codex'
						instance:      'main'
						config_json:   '{"url":"ws://codex.local/main"}'
						desired_state: 'connected'
					}
					'codex/project_demo': provider.ProviderInstanceSpec{
						provider:      'codex'
						instance:      'project_demo'
						config_json:   '{"url":"ws://codex.local/project-demo"}'
						desired_state: 'connected'
					}
				}
			}
		}
	}
	assert app.provider_bootstrap_enabled('codex')
	assert app.provider_runtime_instances('codex') == ['main', 'project_demo']
	assert app.provider_runtime_upstream_enabled('codex', 'project_demo')
	assert app.provider_runtime_pull_url('codex', 'project_demo') or { '' } == 'ws://codex.local/project-demo'
}

fn test_admin_provider_instance_snapshots_include_dynamic_and_static_compat_rows() {
	mut app := App{
		providers: ProviderRuntimeHub{
			feishu:    feishu.FeishuState{
				static_apps: {
					'legacy': config.FeishuAppConfig{
						app_id:     'legacy_app'
						app_secret: 'legacy_secret'
					}
				}
				apps:        {
					'legacy': config.FeishuAppConfig{
						app_id:     'legacy_app'
						app_secret: 'legacy_secret'
					}
					'main':   config.FeishuAppConfig{
						app_id:     'dyn_app'
						app_secret: 'dyn_secret'
					}
				}
				runtime:     {
					'legacy': feishu.ProviderRuntime{
						name:      'legacy'
						connected: true
						ws_url:    'wss://feishu.local/legacy'
					}
					'main':   feishu.ProviderRuntime{
						name:      'main'
						connected: false
						ws_url:    'wss://feishu.local/main'
					}
				}
			}
			codex:     codex.CodexState{
				runtime:   codex.ProviderRuntime{}
				instances: {
					'project_demo': codex.ProviderRuntime{
						instance:  'project_demo'
						connected: true
						ws_url:    'ws://codex.local/project-demo/live'
					}
				}
			}
			instances: provider.ProviderInstanceRegistry{
				specs: {
					'feishu/main':        provider.ProviderInstanceSpec{
						provider:      'feishu'
						instance:      'main'
						config_json:   '{"app_id":"dyn_app","app_secret":"dyn_secret"}'
						desired_state: 'connected'
						created_at:    10
						updated_at:    20
					}
					'codex/project_demo': provider.ProviderInstanceSpec{
						provider:      'codex'
						instance:      'project_demo'
						config_json:   '{"url":"ws://codex.local/project-demo","model":"o4-mini"}'
						desired_state: 'connected'
						created_at:    30
						updated_at:    40
					}
				}
			}
		}
	}
	snapshots := app.admin_provider_instance_snapshots('')
	assert snapshots.len == 3
	assert snapshots[0].provider == 'codex'
	assert snapshots[0].instance == 'project_demo'
	assert snapshots[0].source == 'dynamic'
	assert snapshots[0].runtime_configured
	assert snapshots[0].runtime_connected
	assert snapshots[0].runtime_url == 'ws://codex.local/project-demo/live'
	assert snapshots[0].config_fields == ['model', 'url']
	assert snapshots[1].provider == 'feishu'
	assert snapshots[1].instance == 'legacy'
	assert snapshots[1].source == 'static'
	assert !snapshots[1].stored
	assert snapshots[1].runtime_configured
	assert snapshots[1].runtime_connected
	assert snapshots[1].runtime_url == 'wss://feishu.local/legacy'
	assert snapshots[1].config_present
	assert snapshots[2].provider == 'feishu'
	assert snapshots[2].instance == 'main'
	assert snapshots[2].source == 'dynamic'
	assert snapshots[2].stored
	assert snapshots[2].runtime_configured
	assert !snapshots[2].runtime_connected
	assert snapshots[2].runtime_url == 'wss://feishu.local/main'
	assert snapshots[2].config_fields == ['app_id', 'app_secret']
}

fn test_provider_runtime_upstream_snapshot_helpers() {
	mut app := App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				enabled: true
				apps:    {
					'main': config.FeishuAppConfig{
						app_id: 'test-app'
					}
				}
				runtime: {
					'main': feishu.ProviderRuntime{
						name:      'main'
						connected: true
						ws_url:    'wss://feishu.local/ws'
					}
				}
			}
			codex:  codex.CodexState{
				runtime: codex.ProviderRuntime{
					enabled:          true
					connected:        true
					ws_url:           'wss://codex.local/ws'
					last_error:       ''
					connect_attempts: 2
				}
			}
		}
	}
	feishu_snapshot := app.provider_runtime_upstream_snapshot('feishu', 'main') or {
		upstream.UpstreamSnapshot{}
	}
	assert feishu_snapshot.provider == 'feishu'
	assert feishu_snapshot.instance == 'main'
	assert feishu_snapshot.connected
	codex_snapshot := app.provider_runtime_upstream_snapshot('codex', 'main') or {
		upstream.UpstreamSnapshot{}
	}
	assert codex_snapshot.provider == 'codex'
	assert codex_snapshot.instance == 'main'
	assert codex_snapshot.connected
	assert app.provider_runtime_upstream_snapshots('codex').len == 1
}

fn test_provider_runtime_upstream_events_helper() {
	mut app := App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				enabled: true
				apps:    {
					'main': config.FeishuAppConfig{
						app_id: 'test-app'
					}
				}
				runtime: {
					'main': feishu.ProviderRuntime{
						name:          'main'
						recent_events: [
							feishu.RuntimeEventSnapshot{
								event_type:  'im.message.receive_v1'
								message_id:  'msg-1'
								chat_id:     'chat-1'
								trace_id:    'trace-1'
								received_at: 123
								payload:     '{"ok":true}'
							},
						]
					}
				}
			}
		}
	}
	events := app.provider_runtime_upstream_events('feishu', '')
	assert events.len == 1
	assert events[0].provider == 'feishu'
	assert events[0].instance == 'main'
	assert events[0].message_id == 'msg-1'
}

fn test_provider_runtime_metrics_helper() {
	mut app := App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				runtime: {
					'main': feishu.ProviderRuntime{
						connect_attempts:  3
						connect_successes: 2
						received_frames:   7
						acked_events:      5
						messages_sent:     4
						send_errors:       1
					}
				}
			}
			codex:  codex.CodexState{
				runtime: codex.ProviderRuntime{
					connect_attempts:  6
					connect_successes: 4
					received_frames:   9
				}
			}
		}
	}
	feishu_metrics := app.provider_runtime_metrics('feishu')
	assert feishu_metrics.connect_attempts == 3
	assert feishu_metrics.acked_events == 5
	codex_metrics := app.provider_runtime_metrics('codex')
	assert codex_metrics.connect_attempts == 6
	assert codex_metrics.received_frames == 9
}

fn test_provider_runtime_capabilities_and_gateway_count_helpers() {
	mut app := App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				enabled: true
				apps:    {
					'main': config.FeishuAppConfig{
						app_id: 'test-app'
					}
				}
				runtime: {
					'main': feishu.ProviderRuntime{
						name: 'main'
					}
				}
			}
			codex:  codex.CodexState{
				runtime: codex.ProviderRuntime{
					enabled: true
				}
			}
		}
	}
	caps := app.provider_runtime_capabilities()
	assert caps['feishu_runtime']
	assert caps['feishu_gateway']
	assert app.provider_runtime_gateway_count() == 2
	assert app.provider_runtime_upstream_enabled('feishu', 'main')
	assert app.provider_runtime_upstream_enabled('codex', 'main')
	assert app.provider_runtime_upstream_provider_names() == ['feishu', 'codex']
}

fn test_provider_runtime_upstream_launches_helper() {
	mut app := App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				enabled: true
				apps:    {
					'main': config.FeishuAppConfig{
						app_id: 'test-app'
					}
				}
				runtime: {
					'main': feishu.ProviderRuntime{
						name: 'main'
					}
				}
			}
			codex:  codex.CodexState{
				runtime: codex.ProviderRuntime{
					enabled: true
					url:     'ws://codex.local/ws'
				}
			}
		}
	}
	launches := app.provider_runtime_upstream_launches()
	assert launches.len == 3
	assert launches[0].provider == 'feishu'
	assert launches[1].provider == 'feishu'
	assert launches[1].instance == 'main'
	assert launches[2].provider == 'codex'
	assert launches[2].url == 'ws://codex.local/ws'
}

fn test_provider_runtime_helpers_skip_disabled_feishu_launch_and_gateway_count() {
	mut app := App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				enabled: false
				apps:    {
					'main': config.FeishuAppConfig{
						app_id: 'test-app'
					}
				}
				runtime: {
					'main': feishu.ProviderRuntime{
						name: 'main'
					}
				}
			}
			codex:  codex.CodexState{
				runtime: codex.ProviderRuntime{
					enabled: true
					url:     'ws://codex.local/ws'
				}
			}
		}
	}
	assert app.provider_runtime_instances('feishu') == ['main']
	assert !app.provider_runtime_ready('feishu')
	assert app.provider_runtime_gateway_count() == 1
	assert app.provider_runtime_upstream_provider_names() == ['codex']
	launches := app.provider_runtime_upstream_launches()
	assert launches.len == 1
	assert launches[0].provider == 'codex'
}

fn test_websocket_upstream_provider_helpers_delegate_to_host_facade() {
	mut app := App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				enabled: true
				apps:    {
					'main': config.FeishuAppConfig{
						app_id: 'test-app'
					}
				}
				runtime: {
					'main': feishu.ProviderRuntime{
						name: 'main'
					}
				}
			}
			codex:  codex.CodexState{
				runtime: codex.ProviderRuntime{
					enabled:            true
					url:                'ws://codex.local/ws'
					reconnect_delay_ms: 2222
				}
			}
		}
	}
	assert app.websocket_upstream_provider_pull_url(websocket_upstream_provider_codex, 'main') or {
		''
	} == 'ws://codex.local/ws'
	assert app.websocket_upstream_provider_reconnect_delay_ms(websocket_upstream_provider_codex,
		'main') == 2222
	app.websocket_upstream_provider_on_connecting(websocket_upstream_provider_codex, 'main')
	assert app.providers.codex.runtime.connect_attempts == 1
}

fn test_provider_runtime_lifecycle_helpers_delegate_codex_runtime() {
	mut app := App{
		providers: ProviderRuntimeHub{
			codex: codex.CodexState{
				runtime: codex.ProviderRuntime{
					enabled: true
					url:     'ws://codex.local/ws'
				}
			}
		}
	}
	app.provider_runtime_on_connecting('codex', 'main')
	assert app.providers.codex.runtime.connect_attempts == 1
	app.provider_runtime_on_connected('codex', 'main', 'ws://codex.local/live')
	assert app.providers.codex.runtime.connected
	assert app.providers.codex.runtime.ws_url == 'ws://codex.local/live'
	app.provider_runtime_on_disconnected('codex', 'main', 'test-close')
	assert !app.providers.codex.runtime.connected
	assert app.providers.codex.runtime.last_error == 'test-close'
}

fn test_db_runtime_snapshot_without_compiled_support() {
	mut app := App{
		transport: TransportRuntimeHub{
			db: dbx.Runtime.from_settings(provider.DbRuntimeSettings{
				enabled: true
				socket:  'tmp/vhttpd-db.sock'
				driver:  'mysql'
			})
		}
	}
	assert !dbx.Runtime.compiled()
	assert !app.provider_bootstrap_enabled('db')
	snapshot := app.db_runtime_snapshot()
	assert snapshot.contains('tmp/vhttpd-db.sock')
	assert snapshot.contains('"compiled":false')
	assert snapshot.contains('"last_error":"db_not_compiled"')
}

fn test_db_runtime_dispatch_reports_not_compiled() {
	mut app := App{
		transport: TransportRuntimeHub{
			db: dbx.Runtime{
				enabled: true
				socket:  'tmp/vhttpd-db.sock'
				driver:  'mysql'
			}
		}
	}
	invalid := app.db_runtime_dispatch(dbx.Request{
		mode: 'worker'
		op:   'ping'
	})
	assert !invalid.ok
	assert invalid.error == 'invalid_mode'
	assert invalid.driver == 'mysql'
	resp := app.db_runtime_dispatch(dbx.Request{
		mode: 'db'
		op:   'ping'
	})
	assert !resp.ok
	assert resp.error == 'db_not_compiled'
	assert resp.driver == 'mysql'
}
