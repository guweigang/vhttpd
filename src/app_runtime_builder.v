module main

import json
import os
import time

pub struct AppRuntimeBuildConfig {
pub:
	event_log                     string
	internal_admin_socket         string
	admin_enabled                 bool
	admin_token                   string
	assets_enabled                bool
	assets_prefix                 string
	assets_root                   string
	assets_root_real              string
	assets_cache_control          string
	worker_read_timeout_ms        int
	worker_restart_backoff_ms     int
	worker_restart_backoff_max_ms int
	worker_max_requests           int
	worker_queue_capacity         int
	worker_queue_timeout_ms       int
	workdir                       string
}

fn app_runtime_default_mcp_max_sessions(cfg VhttpdConfig) int {
	return if cfg.mcp.max_sessions > 0 { cfg.mcp.max_sessions } else { 1000 }
}

fn app_runtime_default_mcp_max_pending_messages(cfg VhttpdConfig) int {
	return if cfg.mcp.max_pending_messages > 0 { cfg.mcp.max_pending_messages } else { 128 }
}

fn app_runtime_default_mcp_session_ttl_seconds(cfg VhttpdConfig) int {
	return if cfg.mcp.session_ttl_seconds > 0 { cfg.mcp.session_ttl_seconds } else { 900 }
}

fn build_app_runtime(provider_settings ProviderRuntimeSettings, executor_plan LogicExecutorRuntimePlan, cfg VhttpdConfig, build_cfg AppRuntimeBuildConfig) &App {
	return &App{
		event_log:                                build_cfg.event_log
		started_at_unix:                          time.now().unix()
		worker_backend:                           WorkerBackendRuntime{
			backend:                PhpWorkerBackend{}
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
		worker_backend_mode:                      executor_plan.worker_backend_mode
		logic_executor:                           executor_plan.executor
		logic_executor_lifecycle:                 executor_plan.lifecycle.name()
		internal_admin_socket:                    build_cfg.internal_admin_socket
		stream_dispatch:                          executor_plan.bootstrap.stream_dispatch
		websocket_dispatch_mode:                  executor_plan.bootstrap.websocket_dispatch_mode
		admin_on_data_plane:                      !build_cfg.admin_enabled
		admin_token:                              build_cfg.admin_token
		runtime_config_json:                      json.encode(cfg)
		plugin_configs:                           cfg.plugins.clone()
		plugin_vjsx:                              build_vjsx_plugin_runtimes(cfg.plugins)
		assets_enabled:                           build_cfg.assets_enabled
		assets_prefix:                            build_cfg.assets_prefix
		assets_root:                              build_cfg.assets_root
		assets_root_real:                         build_cfg.assets_root_real
		assets_cache_control:                     build_cfg.assets_cache_control
		mcp_max_sessions:                         app_runtime_default_mcp_max_sessions(cfg)
		mcp_max_pending_messages:                 app_runtime_default_mcp_max_pending_messages(cfg)
		mcp_session_ttl_seconds:                  app_runtime_default_mcp_session_ttl_seconds(cfg)
		mcp_sampling_capability_policy:           normalize_mcp_sampling_capability_policy(cfg.mcp.sampling_capability_policy)
		mcp_allowed_origins:                      cfg.mcp.allowed_origins.clone()
		feishu_enabled:                           provider_settings.feishu.enabled
		feishu_open_base_url:                     provider_settings.feishu.open_base_url
		feishu_reconnect_delay_ms:                provider_settings.feishu.reconnect_delay_ms
		feishu_token_refresh_skew_seconds:        provider_settings.feishu.token_refresh_skew_seconds
		feishu_recent_event_limit:                provider_settings.feishu.recent_event_limit
		openai_enabled:                           cfg.openai.enabled
		openai_base_path:                         cfg.openai.base_path
		openai_default_backend:                   cfg.openai.default_backend
		openai_plugin:                            cfg.openai.plugin
		openai_endpoints:                         cfg.openai.endpoints
		openai_backends:                          cfg.openai.backends.clone()
		openai_routes:                            cfg.openai.routes.clone()
		openai_responses:                         new_memory_state_store[OpenAIResponseRecord]()
		websocket_upstream_recent_dispatch_limit: 50
		auto_start_dynamic_upstreams:             true
		feishu_static_apps:                       provider_settings.feishu.apps.clone()
		feishu_apps:                              provider_settings.feishu.apps.clone()
		upstream_sessions:                        map[string]UpstreamRuntimeSession{}
		mcp_sessions:                             map[string]McpSession{}
		ws_hub_conns:                             map[string]HubConn{}
		ws_hub_room_members:                      map[string]map[string]bool{}
		ws_hub_conn_rooms:                        map[string]map[string]bool{}
		ws_hub_conn_meta:                         map[string]map[string]string{}
		ws_hub_pending:                           map[string][]HubPendingMessage{}
		feishu_runtime:                           map[string]FeishuProviderRuntime{}
		websocket_upstream_started:               map[string]bool{}
		providers:                                ProviderHost{
			registry: map[string]Provider{}
			specs:    map[string]ProviderSpec{}
		}
		ollama_enabled:                           provider_settings.ollama_enabled
		db_runtime:                               build_db_runtime(provider_settings.db)
		fixture_websocket_runtime:                map[string]FixtureWebSocketUpstreamRuntime{}
		websocket_upstream_recent_activities:     []WebSocketUpstreamActivitySnapshot{}
		provider_instance_specs:                  map[string]ProviderInstanceSpec{}
		codex_runtime:                            CodexProviderRuntime{
			enabled:             provider_settings.codex.enabled
			url:                 provider_settings.codex.url
			model:               provider_settings.codex.model
			effort:              provider_settings.codex.effort
			cwd:                 provider_settings.codex.cwd
			approval_policy:     provider_settings.codex.approval_policy
			sandbox:             provider_settings.codex.sandbox
			reconnect_delay_ms:  provider_settings.codex.reconnect_delay_ms
			flush_interval_ms:   provider_settings.codex.flush_interval_ms
			pending_rpcs:        map[int]CodexPendingRpc{}
			stream_map:          map[string][]CodexTarget{}
			err_bursts:          map[string][]string{}
			err_pending_flushes: map[string]bool{}
			thread_stream_map:   map[string]string{}
		}
		codex_instances:                          map[string]CodexProviderRuntime{}
		feishu_buffers:                           map[string]FeishuStreamBuffer{}
		feishu_card_bridge_enabled_flag:          provider_settings.bridge.enabled
		feishu_card_bridge_ws_url:                provider_settings.bridge.ws_url
		feishu_card_bridge_client_id:             provider_settings.bridge.client_id
		feishu_card_bridge_token:                 provider_settings.bridge.token
		feishu_card_bridge_target_id:             provider_settings.bridge.target_id
	}
}

fn prepare_server_runtime_files(event_log string, pid_file string) !string {
	return prepare_server_runtime_files_for_label(event_log, pid_file, '')
}

fn prepare_server_runtime_files_for_label(event_log string, pid_file string, socket_label string) !string {
	os.mkdir_all(os.dir(event_log))!
	os.mkdir_all(os.dir(pid_file))!
	os.write_file(pid_file, '${os.getpid()}')!
	return default_internal_admin_socket_for(socket_label)
}
