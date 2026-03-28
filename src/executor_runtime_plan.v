module main

pub struct LogicExecutorRuntimePlan {
pub:
	executor            LogicExecutor
	worker_backend_mode WorkerBackendMode
	lifecycle           LogicExecutorLifecycle
	bootstrap           ExecutorBootstrapState
}

fn build_executor_bootstrap_state(worker_sockets []string, stream_dispatch bool, websocket_dispatch_mode bool, worker_autostart bool, worker_cmd string, worker_env map[string]string) ExecutorBootstrapState {
	return ExecutorBootstrapState{
		worker_sockets:          worker_sockets.clone()
		stream_dispatch:         stream_dispatch
		websocket_dispatch_mode: websocket_dispatch_mode
		worker_autostart:        worker_autostart
		worker_cmd:              worker_cmd
		worker_env:              worker_env.clone()
	}
}

fn resolve_logic_executor_runtime_plan(args []string, cfg VhttpdConfig, worker_sockets []string, stream_dispatch bool, websocket_dispatch_mode bool, worker_autostart bool, worker_cmd string, worker_env map[string]string) !LogicExecutorRuntimePlan {
	selection := resolve_executor_runtime(args, cfg)!
	mut bootstrap := build_executor_bootstrap_state(worker_sockets, stream_dispatch, websocket_dispatch_mode,
		worker_autostart, worker_cmd, worker_env)
	selection.lifecycle.prepare_bootstrap(args, cfg, mut bootstrap)!
	return LogicExecutorRuntimePlan{
		executor:            selection.executor
		worker_backend_mode: selection.worker_backend_mode
		lifecycle:           selection.lifecycle
		bootstrap:           bootstrap
	}
}
