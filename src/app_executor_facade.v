module main

import executor
import upstream.transport

// App implements the executor capabilities directly; the facade retains this App.

pub fn (app &App) get_runtime_config_json() string {
	return app.protocols.runtime_config_json
}

pub fn (app &App) get_runtime_plan_json() string {
	return app.protocols.runtime_plan_json
}

pub fn (app &App) worker_backend_read_timeout_ms() int {
	return app.engines.read_timeout_ms('')
}

pub fn (app &App) worker_backend_read_timeout_ms_for_kind(kind string) int {
	return app.engines.read_timeout_ms(kind)
}

pub fn (app &App) worker_backend_sockets_len() int {
	return app.engines.primary_socket_count()
}

pub fn (app &App) worker_env() map[string]string {
	return app.engines.worker_env('')
}

pub fn (app &App) worker_env_for_kind(kind string) map[string]string {
	return app.engines.worker_env(kind)
}

pub fn (mut app App) worker_backend_select_socket_for_kind(kind string) !string {
	port := app.build_engine_lifecycle_port()
	return app.engines.select_socket_for_kind(port, kind)
}

pub fn (mut app App) provider_bridge_dispatch_callback(provider string, app_name string, trace_id string, summary executor.FeishuRuntimeEventSummary, payload string) !executor.FeishuCardBridgeResult {
	return match provider {
		websocket_upstream_provider_feishu {
			app.providers.feishu_card_bridge_dispatch_callback(app_name, trace_id, summary,
				payload)!
		}
		else {
			error('provider_bridge_dispatch_unsupported:${provider}')
		}
	}
}

pub fn (mut app App) run_command_envelopes(request_id string, dispatch_ctx DispatchContext, commands []transport.WorkerWebSocketUpstreamCommand) string {
	return app.execute_command_envelopes(request_id, dispatch_ctx, commands)
}

// ── App logic_executor proxy methods ──

pub fn (app &App) logic_executor_kind() string {
	return app.engines.primary_kind()
}

pub fn (app &App) logic_executor_model() executor.LogicExecutorModel {
	return app.engines.logic_executor_model()
}

pub fn (app &App) logic_executor_provider() string {
	return app.engines.logic_executor_provider()
}

pub fn (app &App) logic_executor_admin_details() executor.LogicExecutorAdminDetails {
	return app.engines.logic_executor_admin_details()
}

pub fn (app &App) has_http_logic_executor() bool {
	return app.engines.has_http_logic_executor()
}

pub fn (app &App) has_websocket_upstream_logic_executor() bool {
	return app.engines.has_http_logic_executor()
}

pub fn (mut app App) as_facade() executor.AppFacade {
	return &app
}
