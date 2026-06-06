module executor

import config
import transport
import log

pub struct ExecutorBootstrapState {
pub mut:
	worker_sockets          []string
	stream_dispatch         bool
	websocket_dispatch_mode bool
	worker_autostart        bool
	worker_cmd              string
	worker_env              map[string]string
}

// LogicExecutorLifecycle uses function pointers instead of an interface
// so the start/stop closures can capture App from module main without
// creating circular imports.
pub struct LogicExecutorLifecycle {
pub:
	name_fn             fn () string                                                          = unsafe { nil }
	prepare_bootstrap_fn fn ([]string, config.VhttpdConfig, mut ExecutorBootstrapState) !      = unsafe { nil }
	start_fn            fn (mut LifecycleRuntimeContext)                                      = unsafe { nil }
	stop_fn             fn (mut LifecycleRuntimeContext)                                      = unsafe { nil }
}

pub fn (l LogicExecutorLifecycle) name() string {
	return l.name_fn()
}

pub fn (l LogicExecutorLifecycle) prepare_bootstrap(args []string, cfg config.VhttpdConfig, mut state ExecutorBootstrapState) ! {
	l.prepare_bootstrap_fn(args, cfg, mut state)!
}

pub fn (l LogicExecutorLifecycle) start(mut ctx LifecycleRuntimeContext) {
	l.start_fn(mut ctx)
}

pub fn (l LogicExecutorLifecycle) stop(mut ctx LifecycleRuntimeContext) {
	l.stop_fn(mut ctx)
}

// LifecycleRuntimeContext carries closures for lifecycle operations that
// need access to App state (worker pool management, event emission).
pub struct LifecycleRuntimeContext {
pub mut:
	worker_backend_autostart       bool
	worker_backend_cmd             string
	worker_backend_env             map[string]string = {}
	worker_backend_sockets         []string          = []
	worker_backend_workdir         string
	worker_backend_managed_workers []transport.ManagedWorker = []
	emit                           fn (string, map[string]string) = unsafe { nil }
}

// ── Disabled (noop) lifecycle ──

pub fn disabled_executor_lifecycle() LogicExecutorLifecycle {
	return LogicExecutorLifecycle{
		name_fn: fn () string {
			return 'disabled'
		}
		prepare_bootstrap_fn: fn (args []string, cfg config.VhttpdConfig, mut state ExecutorBootstrapState) ! {
			_ = args
			_ = cfg
			state.worker_sockets = []string{}
			state.worker_autostart = false
			state.worker_cmd = ''
			state.stream_dispatch = false
			state.websocket_dispatch_mode = false
		}
		start_fn: fn (mut ctx LifecycleRuntimeContext) {
			_ = ctx
		}
		stop_fn: fn (mut ctx LifecycleRuntimeContext) {
			_ = ctx
		}
	}
}

// ── PHP Worker lifecycle ──

pub fn php_worker_executor_lifecycle() LogicExecutorLifecycle {
	return LogicExecutorLifecycle{
		name_fn: fn () string {
			return 'php_worker_host'
		}
		prepare_bootstrap_fn: fn (args []string, cfg config.VhttpdConfig, mut state ExecutorBootstrapState) ! {
			php_spec := builtin_executor_spec_find('php')!
			php_cfg := php_spec.resolve_php_runtime_config(args, cfg)!
			state.worker_env = php_worker_runtime_build_env(state.worker_env, php_cfg)
			if state.worker_cmd.trim_space() == '' {
				state.worker_cmd = php_worker_runtime_build_command(php_cfg)!
			}
		}
		start_fn: fn (mut ctx LifecycleRuntimeContext) {
			if !ctx.worker_backend_autostart {
				return
			}
			ctx.worker_backend_managed_workers = transport.ManagedWorkerPool.start(ctx.worker_backend_cmd,
				ctx.worker_backend_env, ctx.worker_backend_sockets,
				ctx.worker_backend_workdir)
			if ctx.worker_backend_managed_workers.len == 0
				&& ctx.worker_backend_sockets.len > 0 {
				log.warn('worker pool is empty after startup; server will stay up and keep retrying')
				ctx.emit('worker.pool.empty', {
					'worker_pool_size': '${ctx.worker_backend_sockets.len}'
					'worker_cmd':       ctx.worker_backend_cmd
				})
			}
			for worker in ctx.worker_backend_managed_workers {
				mut w := worker
				if !isnil(w.proc) && w.proc.is_alive() {
					ctx.emit('worker.started', {
						'worker_id':     '${w.id}'
						'socket':        w.socket_path
						'restart_count': '${w.restart_count}'
					})
				} else {
					ctx.emit('worker.restart_scheduled', {
						'worker_id':     '${w.id}'
						'socket':        w.socket_path
						'restart_count': '${w.restart_count}'
						'next_retry_ts': '${w.next_retry_ts}'
						'reason':        'initial_start_failed'
					})
				}
			}
		}
		stop_fn: fn (mut ctx LifecycleRuntimeContext) {
			transport.ManagedWorkerPool.stop(mut ctx.worker_backend_managed_workers)
		}
	}
}

// ── Embedded (vjsx) lifecycle ──

pub fn embedded_executor_lifecycle() LogicExecutorLifecycle {
	return LogicExecutorLifecycle{
		name_fn: fn () string {
			return 'embedded_host'
		}
		prepare_bootstrap_fn: fn (args []string, cfg config.VhttpdConfig, mut state ExecutorBootstrapState) ! {
			_ = args
			_ = cfg
			state.worker_sockets = []string{}
			state.worker_autostart = false
			state.worker_cmd = ''
			state.stream_dispatch = false
		}
		start_fn: fn (mut ctx LifecycleRuntimeContext) {
			_ = ctx
		}
		stop_fn: fn (mut ctx LifecycleRuntimeContext) {
			_ = ctx
		}
	}
}
