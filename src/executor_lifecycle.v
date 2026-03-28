module main

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

pub interface LogicExecutorLifecycle {
	name() string
	prepare_bootstrap(args []string, cfg VhttpdConfig, mut state ExecutorBootstrapState) !
	start(mut app App)
	stop(mut app App)
}

pub struct PhpWorkerExecutorLifecycle {}

pub fn (l PhpWorkerExecutorLifecycle) name() string {
	_ = l
	return 'php_worker_host'
}

pub fn (l PhpWorkerExecutorLifecycle) prepare_bootstrap(args []string, cfg VhttpdConfig, mut state ExecutorBootstrapState) ! {
	_ = l
	php_cfg := build_php_runtime_config(args, cfg)!
	state.worker_env = build_php_worker_env(state.worker_env, php_cfg)
	if state.worker_cmd.trim_space() == '' {
		state.worker_cmd = build_php_worker_command(php_cfg)!
	}
}

pub fn (l PhpWorkerExecutorLifecycle) start(mut app App) {
	_ = l
	if !app.worker_backend.autostart {
		return
	}
	app.worker_backend.managed_workers = start_worker_pool(app.worker_backend.cmd, app.worker_backend.env,
		app.worker_backend.sockets, app.worker_backend.workdir)
	if app.worker_backend.managed_workers.len == 0 && app.worker_backend.sockets.len > 0 {
		log.warn('worker pool is empty after startup; server will stay up and keep retrying')
		app.emit('worker.pool.empty', {
			'worker_pool_size': '${app.worker_backend.sockets.len}'
			'worker_cmd':       app.worker_backend.cmd
		})
	}
	for worker in app.worker_backend.managed_workers {
		mut w := worker
		if !isnil(w.proc) && w.proc.is_alive() {
			app.emit('worker.started', {
				'worker_id':     '${w.id}'
				'socket':        w.socket_path
				'restart_count': '${w.restart_count}'
			})
		} else {
			app.emit('worker.restart_scheduled', {
				'worker_id':     '${w.id}'
				'socket':        w.socket_path
				'restart_count': '${w.restart_count}'
				'next_retry_ts': '${w.next_retry_ts}'
				'reason':        'initial_start_failed'
			})
		}
	}
}

pub fn (l PhpWorkerExecutorLifecycle) stop(mut app App) {
	_ = l
	stop_worker_pool(mut app.worker_backend.managed_workers)
}

pub struct EmbeddedExecutorLifecycle {}

pub fn (l EmbeddedExecutorLifecycle) name() string {
	_ = l
	return 'embedded_host'
}

pub fn (l EmbeddedExecutorLifecycle) prepare_bootstrap(args []string, cfg VhttpdConfig, mut state ExecutorBootstrapState) ! {
	_ = l
	_ = args
	_ = cfg
	state.worker_sockets = []string{}
	state.worker_autostart = false
	state.worker_cmd = ''
	state.stream_dispatch = false
	state.websocket_dispatch_mode = false
}

pub fn (l EmbeddedExecutorLifecycle) start(mut app App) {
	_ = l
	_ = app
}

pub fn (l EmbeddedExecutorLifecycle) stop(mut app App) {
	_ = l
	_ = app
}
