module executor

import config

pub struct LogicExecutorRuntimePlan {
pub:
	executor            LogicExecutor
	worker_backend_mode WorkerBackendMode
	lifecycle           LogicExecutorLifecycle
	bootstrap           ExecutorBootstrapState
}

pub fn LogicExecutorRuntimePlan.resolve(args []string, cfg config.VhttpdConfig, worker_sockets []string, stream_dispatch bool, websocket_dispatch_mode bool, worker_autostart bool, worker_cmd string, worker_env map[string]string) !LogicExecutorRuntimePlan {
	factory := ExecutorFactory.new_default()
	selection := ExecutorRuntimeSelection.resolve(args, cfg, factory)!
	mut bootstrap := ExecutorBootstrapState{
		worker_sockets:          worker_sockets.clone()
		stream_dispatch:         stream_dispatch
		websocket_dispatch_mode: websocket_dispatch_mode
		worker_autostart:        worker_autostart
		worker_cmd:              worker_cmd
		worker_env:              worker_env.clone()
	}
	selection.lifecycle.prepare_bootstrap(args, cfg, mut bootstrap)!
	return LogicExecutorRuntimePlan{
		executor:            selection.executor
		worker_backend_mode: selection.worker_backend_mode
		lifecycle:           selection.lifecycle
		bootstrap:           bootstrap
	}
}
