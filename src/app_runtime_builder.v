module main

import cachex
import dbx
import config
import codex
import api.mcp.protocol as mcp_protocol
import api.openai
import provider
import json
import state_store
import time
import upstream
import ws
import worker
import admin
import plugin
import feishu
import executor
import server_lifecycle
import regex

fn app_runtime_default_mcp_max_sessions(cfg config.VhttpdConfig) int {
	return if cfg.mcp.max_sessions > 0 { cfg.mcp.max_sessions } else { 1000 }
}

fn app_runtime_default_mcp_max_pending_messages(cfg config.VhttpdConfig) int {
	return if cfg.mcp.max_pending_messages > 0 { cfg.mcp.max_pending_messages } else { 128 }
}

fn app_runtime_default_mcp_session_ttl_seconds(cfg config.VhttpdConfig) int {
	return if cfg.mcp.session_ttl_seconds > 0 { cfg.mcp.session_ttl_seconds } else { 900 }
}

fn build_app_runtime(provider_settings provider.ProviderRuntimeSettings, executor_plan executor.LogicExecutorRuntimePlan, cfg config.VhttpdConfig, build_cfg server_lifecycle.AppRuntimeBuildConfig) &App {
	// 1. 预编译正则并构建运行时路由规则
	mut runtime_routes := []RuntimeRouteRule{}
	expanded_routes := config.expand_php_site_routes(cfg)
	for r in expanded_routes {
		mut re := regex.RE{}
		if r.match.path_regexp != '' {
			re = regex.regex_opt(r.match.path_regexp) or { continue }
		}
		runtime_routes << RuntimeRouteRule{
			match_path:           r.match.path.clone()
			match_path_regexp:    r.match.path_regexp
			match_query:          r.match.query.clone()
			re:                   re
			executor:             r.executor
			rewrite:              r.rewrite
			rewrite_strip_prefix: r.rewrite_strip_prefix
			root:                 r.root
			status:               r.status
			location:             r.location
			body:                 r.body
		}
	}

	// 2. 遍历 routes 中的所有附加 executor，如果有专属的进程池配置则实例化其 WorkerState
	mut add_workers := map[string]&worker.WorkerState{}
	for route in expanded_routes {
		if route.executor != '' && route.executor != cfg.executor.kind
			&& route.executor !in add_workers {
			if spec := cfg.executors[route.executor] {
				mut sub_cfg := cfg
				sub_cfg.worker = spec.worker
				sub_cfg.php = spec.php
				sub_cfg.vjsx = spec.vjsx
				sub_cfg.executor = spec.executor

				sub_sockets := config.resolve_worker_sockets_with_defaults([]string{},
					spec.worker.socket, spec.worker.pool_size, spec.worker.socket_prefix,
					spec.worker.sockets.join(','))
				sub_plan := executor.LogicExecutorRuntimePlan.resolve([]string{}, sub_cfg,
					sub_sockets, spec.worker.stream_dispatch, spec.worker.websocket_dispatch,
					spec.worker.autostart, spec.worker.cmd, spec.worker.env) or { continue }
				sub_queue_capacity := if spec.worker.queue_capacity > 0 {
					spec.worker.queue_capacity
				} else {
					build_cfg.worker_queue_capacity
				}
				sub_queue_timeout_ms := if spec.worker.queue_timeout_ms > 0 {
					spec.worker.queue_timeout_ms
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
				add_workers[route.executor] = sub_ws
			}
		}
	}

	return &App{
		event_log:          build_cfg.event_log
		started_at_unix:    time.now().unix()
		http_stats:         HttpStats{}
		admin:              admin.AdminState{
			internal_socket: build_cfg.internal_admin_socket
			on_data_plane:   !build_cfg.admin_enabled
			token:           build_cfg.admin_token
		}
		assets:             config.AssetsRuntime{
			enabled:       build_cfg.assets_enabled
			prefix:        build_cfg.assets_prefix
			root:          build_cfg.assets_root
			root_real:     build_cfg.assets_root_real
			cache_control: build_cfg.assets_cache_control
		}
		protocols:          ProtocolRuntimeHub{
			runtime_config_json: json.encode(cfg)
			plugins:             plugin.PluginState{
				configs: cfg.plugins.clone()
				vjsx:    build_vjsx_plugin_runtimes(cfg.plugins)
			}
			mcp:                 mcp_protocol.McpState{
				max_sessions:               app_runtime_default_mcp_max_sessions(cfg)
				max_pending_messages:       app_runtime_default_mcp_max_pending_messages(cfg)
				session_ttl_seconds:        app_runtime_default_mcp_session_ttl_seconds(cfg)
				sampling_capability_policy: mcp_protocol.McpState.normalize_sampling_capability_policy(cfg.mcp.sampling_capability_policy)
				allowed_origins:            cfg.mcp.allowed_origins.clone()
				sessions:                   map[string]mcp_protocol.Session{}
			}
			openai:              openai.OpenaiState{
				enabled:         cfg.openai.enabled
				base_path:       cfg.openai.base_path
				default_backend: cfg.openai.default_backend
				plugin:          cfg.openai.plugin
				endpoints:       cfg.openai.endpoints
				backends:        cfg.openai.backends.clone()
				routes:          cfg.openai.routes.clone()
				responses:       state_store.MemoryStateStore.new[openai.OpenAIResponseRecord]()
			}
		}
		transport:          TransportRuntimeHub{
			websocket: ws.HubState{
				dispatch_mode:                executor_plan.bootstrap.websocket_dispatch_mode
				recent_dispatch_limit:        50
				auto_start_dynamic_upstreams: true
				upstream_sessions:            map[string]upstream.UpstreamRuntimeSession{}
				conns:                        map[string]ws.HubConn{}
				room_members:                 map[string]map[string]bool{}
				conn_rooms:                   map[string]map[string]bool{}
				conn_meta:                    map[string]map[string]string{}
				pending:                      map[string][]ws.HubPendingMessage{}
				upstream_started:             map[string]bool{}
				fixture_runtime:              map[string]ws.FixtureRuntime{}
				recent_activities:            []ws.UpstreamActivitySnapshot{}
			}
			db:        dbx.Runtime.from_settings(provider_settings.db)
			cache:     cachex.Runtime.new(cfg.cache.enabled, cfg.cache.socket)
		}
		executors:          ExecutorRuntimeHub{
			worker: worker.WorkerState{
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
		}
		providers:          ProviderRuntimeHub{
			registry:  ProviderHost{
				registry: map[string]Provider{}
				specs:    map[string]ProviderSpec{}
			}
			instances: provider.ProviderInstanceRegistry{
				specs: map[string]provider.ProviderInstanceSpec{}
			}
			codex:     codex.CodexState{
				ollama_enabled: provider_settings.ollama_enabled
				runtime:        codex.ProviderRuntime{
					enabled:             provider_settings.codex.enabled
					url:                 provider_settings.codex.url
					model:               provider_settings.codex.model
					effort:              provider_settings.codex.effort
					cwd:                 provider_settings.codex.cwd
					approval_policy:     provider_settings.codex.approval_policy
					sandbox:             provider_settings.codex.sandbox
					reconnect_delay_ms:  provider_settings.codex.reconnect_delay_ms
					flush_interval_ms:   provider_settings.codex.flush_interval_ms
					pending_rpcs:        map[int]codex.PendingRpc{}
					stream_map:          map[string][]codex.CodexTarget{}
					err_bursts:          map[string][]string{}
					err_pending_flushes: map[string]bool{}
					thread_stream_map:   map[string]string{}
				}
				instances:      map[string]codex.ProviderRuntime{}
			}
			feishu:    feishu.FeishuState{
				enabled:                    provider_settings.feishu.enabled
				open_base_url:              provider_settings.feishu.open_base_url
				reconnect_delay_ms:         provider_settings.feishu.reconnect_delay_ms
				token_refresh_skew_seconds: provider_settings.feishu.token_refresh_skew_seconds
				recent_event_limit:         provider_settings.feishu.recent_event_limit
				static_apps:                provider_settings.feishu.apps.clone()
				apps:                       provider_settings.feishu.apps.clone()
				runtime:                    map[string]feishu.ProviderRuntime{}
				buffers:                    map[string]feishu.StreamBuffer{}
				card_bridge_enabled_flag:   provider_settings.bridge.enabled
				card_bridge_ws_url:         provider_settings.bridge.ws_url
				card_bridge_client_id:      provider_settings.bridge.client_id
				card_bridge_token:          provider_settings.bridge.token
				card_bridge_target_id:      provider_settings.bridge.target_id
			}
		}
		routes:             runtime_routes
		additional_workers: add_workers
	}
}
