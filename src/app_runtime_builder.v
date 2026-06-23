module main

import cachex
import dbx
import config
import codex
import provider
import json
import time
import worker
import admin
import plugin
import feishu
import executor
import server_lifecycle
import runtime_plan

fn build_app_runtime(provider_settings provider.ProviderRuntimeSettings, executor_plan executor.LogicExecutorRuntimePlan, cfg config.VhttpdConfig, plan runtime_plan.RuntimePlan, build_cfg server_lifecycle.AppRuntimeBuildConfig) &App {
	// 1. Build request-time routes only from the resolved plan for this listener.
	plan_listener_id := if build_cfg.plan_listener_id != '' {
		build_cfg.plan_listener_id
	} else {
		'default'
	}
	runtime_routes := runtime_routes_from_plan(plan, plan_listener_id)
	db_settings := db_runtime_settings_from_plan(plan, plan_listener_id)
	cache_enabled, cache_socket := cache_runtime_settings_from_plan(plan, plan_listener_id)
	mcp_state := mcp_state_from_plan(plan, plan_listener_id)
	openai_state := openai_state_from_plan(plan, plan_listener_id)
	plugin_configs := plugin_configs_from_plan(plan)
	plan_provider_settings := provider_runtime_settings_from_plan(plan, provider_settings)

	// 2. 遍历 routes 中的所有附加 executor，如果有专属的进程池配置则实例化其 WorkerState
	mut add_workers := map[string]&worker.WorkerState{}
	for route in runtime_routes {
		mut executor_names := []string{}
		if route.executor != '' {
			executor_names << route.executor
		}
		if route.on_completed.trim_space().starts_with('vjsx:') {
			executor_names << 'vjsx'
		}
		for executor_name in executor_names {
			if executor_name == '' || executor_name == executor_plan.executor.kind()
				|| executor_name in add_workers {
				continue
			}
			if engine := plan.listener_named_engine(plan_listener_id, executor_name) {
				mut sub_cfg := cfg
				mut spec := config.ExecutorSpecConfig{}
				if fallback_spec := cfg.executors[executor_name] {
					spec = fallback_spec
				}
				sub_cfg.worker = spec.worker
				sub_cfg.php = spec.php
				sub_cfg.vjsx = spec.vjsx
				sub_cfg.executor = spec.executor

				sub_plan := executor.LogicExecutorRuntimePlan.resolve_engine_from_plan(sub_cfg,
					engine) or { continue }
				sub_queue_capacity := if engine.options.ints['queue_capacity'] > 0 {
					engine.options.ints['queue_capacity']
				} else {
					build_cfg.worker_queue_capacity
				}
				sub_queue_timeout_ms := if engine.options.ints['queue_timeout_ms'] > 0 {
					engine.options.ints['queue_timeout_ms']
				} else {
					build_cfg.worker_queue_timeout_ms
				}

				mut sub_ws := &worker.WorkerState{
					worker_backend:      worker.WorkerBackendRuntime{
						backend:                worker.PhpWorkerBackend{}
						sockets:                sub_plan.bootstrap.worker_sockets.clone()
						read_timeout_ms:        build_cfg.worker_read_timeout_ms
						autostart:              sub_plan.bootstrap.worker_autostart
						cmd:                    sub_plan.bootstrap.worker_cmd
						env:                    sub_plan.bootstrap.worker_env.clone()
						workdir:                build_cfg.workdir
						restart_backoff_ms:     build_cfg.worker_restart_backoff_ms
						restart_backoff_max_ms: build_cfg.worker_restart_backoff_max_ms
						max_requests:           build_cfg.worker_max_requests
						queue_capacity:         sub_queue_capacity
						queue_timeout_ms:       sub_queue_timeout_ms
						queue_poll_ms:          10
					}
					worker_backend_mode: sub_plan.worker_backend_mode
					logic_executor:      sub_plan.executor
					lifecycle:           sub_plan.lifecycle.name()
					stream_dispatch:     sub_plan.bootstrap.stream_dispatch
				}
				add_workers[executor_name] = sub_ws
			}
		}
	}

	return &App{
		plan:          plan
		control_plane: ControlPlaneRuntime{
			event_log:  build_cfg.event_log
			http_stats: HttpStats{}
			admin:      admin.AdminState{
				internal_socket: build_cfg.internal_admin_socket
				on_data_plane:   !build_cfg.admin_enabled
				token:           build_cfg.admin_token
			}
		}
		lifecycle:     ProcessLifecycle{
			started_at_unix: time.now().unix()
		}
		assets:        config.AssetsRuntime{
			enabled:       build_cfg.assets_enabled
			prefix:        build_cfg.assets_prefix
			root:          build_cfg.assets_root
			root_real:     build_cfg.assets_root_real
			cache_control: build_cfg.assets_cache_control
		}
		protocols:     ProtocolRuntimeHub{
			runtime_config_json: json.encode(cfg)
			runtime_plan_json:   json.encode(plan)
			plugins:             plugin.PluginState{
				configs: plugin_configs.clone()
				vjsx:    build_vjsx_plugin_runtimes(plugin_configs)
			}
			mcp:                 mcp_state
			openai:              openai_state
		}
		transport:     TransportRuntimeHub{
			db:    dbx.Runtime.from_settings(db_settings)
			cache: cachex.Runtime.new(cache_enabled, cache_socket)
		}
		websocket:     WebSocketRuntime.new(executor_plan.bootstrap.websocket_dispatch_mode)
		upstreams:     UpstreamRuntimeRegistry.new()
		engines:       EngineRuntime{
			primary:    worker.WorkerState{
				worker_backend:      worker.WorkerBackendRuntime{
					backend:                worker.PhpWorkerBackend{}
					sockets:                executor_plan.bootstrap.worker_sockets
					read_timeout_ms:        build_cfg.worker_read_timeout_ms
					autostart:              executor_plan.bootstrap.worker_autostart
					cmd:                    executor_plan.bootstrap.worker_cmd
					env:                    executor_plan.bootstrap.worker_env
					workdir:                build_cfg.workdir
					restart_backoff_ms:     build_cfg.worker_restart_backoff_ms
					restart_backoff_max_ms: build_cfg.worker_restart_backoff_max_ms
					max_requests:           build_cfg.worker_max_requests
					queue_capacity:         build_cfg.worker_queue_capacity
					queue_timeout_ms:       build_cfg.worker_queue_timeout_ms
					queue_poll_ms:          10
				}
				worker_backend_mode: executor_plan.worker_backend_mode
				logic_executor:      executor_plan.executor
				lifecycle:           executor_plan.lifecycle.name()
				stream_dispatch:     executor_plan.bootstrap.stream_dispatch
			}
			additional: add_workers
		}
		providers:     ProviderRuntimeHub{
			registry:  ProviderHost{
				registry: map[string]Provider{}
				specs:    map[string]ProviderSpec{}
			}
			instances: provider.ProviderInstanceRegistry{
				specs: map[string]provider.ProviderInstanceSpec{}
			}
			codex:     codex.CodexState{
				ollama_enabled: plan_provider_settings.ollama_enabled
				runtime:        codex.ProviderRuntime{
					enabled:             plan_provider_settings.codex.enabled
					url:                 plan_provider_settings.codex.url
					model:               plan_provider_settings.codex.model
					effort:              plan_provider_settings.codex.effort
					cwd:                 plan_provider_settings.codex.cwd
					approval_policy:     plan_provider_settings.codex.approval_policy
					sandbox:             plan_provider_settings.codex.sandbox
					reconnect_delay_ms:  plan_provider_settings.codex.reconnect_delay_ms
					flush_interval_ms:   plan_provider_settings.codex.flush_interval_ms
					pending_rpcs:        map[int]codex.PendingRpc{}
					stream_map:          map[string][]codex.CodexTarget{}
					err_bursts:          map[string][]string{}
					err_pending_flushes: map[string]bool{}
					thread_stream_map:   map[string]string{}
				}
				instances:      map[string]codex.ProviderRuntime{}
			}
			feishu:    feishu.FeishuState{
				enabled:                    plan_provider_settings.feishu.enabled
				open_base_url:              plan_provider_settings.feishu.open_base_url
				reconnect_delay_ms:         plan_provider_settings.feishu.reconnect_delay_ms
				token_refresh_skew_seconds: plan_provider_settings.feishu.token_refresh_skew_seconds
				recent_event_limit:         plan_provider_settings.feishu.recent_event_limit
				static_apps:                plan_provider_settings.feishu.apps.clone()
				apps:                       plan_provider_settings.feishu.apps.clone()
				runtime:                    map[string]feishu.ProviderRuntime{}
				buffers:                    map[string]feishu.StreamBuffer{}
				card_bridge_enabled_flag:   plan_provider_settings.bridge.enabled
				card_bridge_ws_url:         plan_provider_settings.bridge.ws_url
				card_bridge_client_id:      plan_provider_settings.bridge.client_id
				card_bridge_token:          plan_provider_settings.bridge.token
				card_bridge_target_id:      plan_provider_settings.bridge.target_id
			}
		}
		http_routing:  HttpRoutingRuntime.new(runtime_routes, build_cfg.assets_root_real,
			build_cfg.workdir, executor_plan.bootstrap.worker_env, add_workers)
	}
}
