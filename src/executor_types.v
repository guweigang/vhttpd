module main

import executor

// ── Global Type Aliases ──

pub type PluginCallRequest = executor.PluginCallRequest
pub type PluginCallResponse = executor.PluginCallResponse
pub type PluginStreamCallResponse = executor.PluginStreamCallResponse
pub type PluginStreamFrameFn = fn (string) !bool

pub type VjsxRuntimeFacadeConfig = executor.VjsxRuntimeFacadeConfig
pub type InProcVjsxExecutor = executor.InProcVjsxExecutor

pub fn new_inproc_vjsx_executor(config executor.VjsxRuntimeFacadeConfig) executor.InProcVjsxExecutor {
	return executor.new_inproc_vjsx_executor(config)
}

// build_executor_factory delegates to executor module's default factory.
pub fn build_executor_factory() executor.ExecutorFactory {
	return executor.ExecutorFactory.new_default()
}

