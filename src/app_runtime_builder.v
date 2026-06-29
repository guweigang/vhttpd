module main

import cachex
import dbx
import config
import log
import provider
import json
import time
import admin
import plugin
import executor
import server_lifecycle
import runtime_plan

fn build_app_runtime(provider_settings provider.ProviderRuntimeSettings, executor_plan executor.LogicExecutorRuntimePlan, cfg config.VhttpdConfig, plan runtime_plan.RuntimePlan, build_cfg server_lifecycle.AppRuntimeBuildConfig) &App {
	mut runtime_plan_for_app := runtime_plan_with_projection_diagnostics(plan)
	// 1. Build request-time routes only from the resolved plan for this listener.
	plan_listener_id := if build_cfg.plan_listener_id != '' {
		build_cfg.plan_listener_id
	} else {
		'default'
	}
	runtime_routes := runtime_routes_from_plan(runtime_plan_for_app, plan_listener_id)
	runtime_plan_for_app = runtime_plan_with_appended_diagnostics(runtime_plan_for_app, runtime_route_projection_diagnostics(runtime_plan_for_app,
		plan_listener_id))
	log.debug('[vhttpd] runtime routes listener=${plan_listener_id} count=${runtime_routes.len} routes=${runtime_routes.map('${it.pipeline_id}:${it.executor}:${it.match_path}').join('|')}')
	db_settings := db_runtime_settings_from_plan(runtime_plan_for_app, plan_listener_id)
	cache_enabled, cache_socket := cache_runtime_settings_from_plan(runtime_plan_for_app,
		plan_listener_id)
	runtime_plan_for_app = runtime_plan_with_appended_diagnostics(runtime_plan_for_app, protocol_runtime_diagnostics_from_plan(runtime_plan_for_app,
		plan_listener_id))
	mcp_state := mcp_state_from_plan(runtime_plan_for_app, plan_listener_id)
	openai_state := openai_state_from_plan(runtime_plan_for_app, plan_listener_id)
	plugin_configs := plugin_configs_from_plan(runtime_plan_for_app)
	plan_provider_settings := provider_runtime_settings_from_plan(runtime_plan_for_app,
		plan_listener_id, provider_settings)

	engine_build := build_engine_runtime_with_diagnostics_from_plan(cfg, executor_plan,
		runtime_plan_for_app, plan_listener_id, runtime_routes, build_cfg)
	engine_runtime := engine_build.runtime
	runtime_plan_for_app = runtime_plan_with_appended_diagnostics(runtime_plan_for_app,
		engine_build.diagnostics)
	relay_build := relay_runtime_with_diagnostics_from_plan(runtime_plan_for_app)
	runtime_plan_for_app = runtime_plan_with_appended_diagnostics(runtime_plan_for_app,
		relay_build.diagnostics)

	return &App{
		plan:          runtime_plan_for_app
		legacy_config: cfg
		app_build_cfg: build_cfg
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
			runtime_plan_json:   json.encode(runtime_plan_for_app)
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
		relay:         relay_build.runtime
		transformers:  TransformerRuntimeHub.from_plan(runtime_plan_for_app)
		engines:       engine_runtime
		providers:     provider_runtime_hub_from_settings(plan_provider_settings)
		pipelines:     PipelineRuntime.new(runtime_plan_for_app, plan_listener_id, runtime_routes,
			build_cfg.assets_root_real, build_cfg.workdir, executor_plan.bootstrap.worker_env,
			engine_runtime.additional)
	}
}
