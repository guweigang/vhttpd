module main

import executor
import transport
import net.http
import net.unix

// ── AppFacade Implementation ──

pub fn (app &App) runtime_config_json() string {
	return app.runtime_config_json
}

pub fn (app &App) worker_backend_read_timeout_ms() int {
	return app.worker_backend.read_timeout_ms
}

pub fn (app &App) worker_backend_sockets_len() int {
	return app.worker_backend.sockets.len
}

// ── App logic_executor proxy methods ──

pub fn (app &App) logic_executor_kind() string {
	return app.logic_executor.kind()
}

pub fn (app &App) logic_executor_model() executor.LogicExecutorModel {
	return app.logic_executor.model()
}

pub fn (app &App) logic_executor_provider() string {
	return app.logic_executor.provider()
}

pub fn (app &App) logic_executor_admin_details() executor.LogicExecutorAdminDetails {
	return app.logic_executor.admin_details()
}

pub fn (app &App) has_http_logic_executor() bool {
	return app.worker_backend.sockets.len > 0 || app.logic_executor.model() == .embedded
}

pub fn (app &App) has_websocket_upstream_logic_executor() bool {
	return app.worker_backend.sockets.len > 0 || app.logic_executor.model() == .embedded
}

// ── Global Type Aliases ──

pub type PluginCallRequest = executor.PluginCallRequest
pub type PluginCallResponse = executor.PluginCallResponse
pub type PluginStreamCallResponse = executor.PluginStreamCallResponse
pub type PluginStreamFrameFn = fn (string) !bool

pub type LogicExecutor = executor.LogicExecutor
pub type DisabledLogicExecutor = executor.DisabledLogicExecutor
pub type SocketWorkerExecutor = executor.SocketWorkerExecutor
pub type VjsxRuntimeFacadeConfig = executor.VjsxRuntimeFacadeConfig
pub type InProcVjsxExecutor = executor.InProcVjsxExecutor

pub fn new_inproc_vjsx_executor(config executor.VjsxRuntimeFacadeConfig) executor.InProcVjsxExecutor {
	return executor.new_inproc_vjsx_executor(config)
}


