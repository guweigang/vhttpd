module main

import os

pub struct ServerRuntimeConfig {
pub:
	host                  string
	port                  int
	pid_file              string
	admin_enabled         bool
	admin_host            string
	admin_port            int
	admin_token           string
	internal_admin_socket string
	provider_settings     ProviderRuntimeSettings
	executor_plan         LogicExecutorRuntimePlan
	app_build_cfg         AppRuntimeBuildConfig
}

fn resolve_server_runtime_config(args []string, cfg VhttpdConfig) !ServerRuntimeConfig {
	host := arg_string_or(args, '--host', cfg.server.host)
	port := arg_int_or(args, '--port', cfg.server.port)
	event_log := arg_string_or(args, '--event-log', cfg.files.event_log)
	pid_file := arg_string_or(args, '--pid-file', cfg.files.pid_file)
	worker_read_timeout_ms := arg_int_or(args, '--worker-read-timeout-ms', cfg.worker.read_timeout_ms)
	worker_cmd_override := arg_string_or(args, '--worker-cmd', cfg.worker.cmd)
	worker_autostart := arg_bool_or(args, '--worker-autostart', cfg.worker.autostart)
	worker_restart_backoff_ms := arg_int_or(args, '--worker-restart-backoff-ms', cfg.worker.restart_backoff_ms)
	worker_restart_backoff_max_ms := arg_int_or(args, '--worker-restart-backoff-max-ms',
		cfg.worker.restart_backoff_max_ms)
	worker_max_requests := arg_int_or(args, '--worker-max-requests', cfg.worker.max_requests)
	worker_queue_capacity := arg_int_or(args, '--worker-queue-capacity', cfg.worker.queue_capacity)
	worker_queue_timeout_ms := arg_int_or(args, '--worker-queue-timeout-ms', cfg.worker.queue_timeout_ms)
	assets_enabled := cfg.assets.enabled
	assets_prefix := normalize_assets_prefix(cfg.assets.prefix)
	assets_root := cfg.assets.root
	assets_root_real := if assets_root.trim_space() == '' { '' } else { os.real_path(assets_root) }
	assets_cache_control := cfg.assets.cache_control
	admin_host_arg := arg_string_or(args, '--admin-host', cfg.admin.host).trim_space()
	admin_port := arg_int_or(args, '--admin-port', cfg.admin.port)
	admin_token := arg_string_or(args, '--admin-token', cfg.admin.token)
	admin_enabled := admin_port > 0
	admin_host := if admin_host_arg == '' { '127.0.0.1' } else { admin_host_arg }
	provider_settings := resolve_provider_runtime_settings(args, cfg)
	executor_plan := resolve_logic_executor_runtime_plan(args, cfg, resolve_worker_sockets_with_defaults(args,
		cfg.worker.socket, cfg.worker.pool_size, cfg.worker.socket_prefix, cfg.worker.sockets.join(',')),
		cfg.worker.stream_dispatch, cfg.worker.websocket_dispatch, worker_autostart, worker_cmd_override,
		cfg.worker.env.clone())!
	workdir := os.getwd()
	internal_admin_socket := prepare_server_runtime_files(event_log, pid_file)!
	return ServerRuntimeConfig{
		host:                  host
		port:                  port
		pid_file:              pid_file
		admin_enabled:         admin_enabled
		admin_host:            admin_host
		admin_port:            admin_port
		admin_token:           admin_token
		internal_admin_socket: internal_admin_socket
		provider_settings:     provider_settings
		executor_plan:         executor_plan
		app_build_cfg:         AppRuntimeBuildConfig{
			event_log:                     event_log
			internal_admin_socket:         internal_admin_socket
			admin_enabled:                 admin_enabled
			admin_token:                   admin_token
			assets_enabled:                assets_enabled
			assets_prefix:                 assets_prefix
			assets_root:                   assets_root
			assets_root_real:              assets_root_real
			assets_cache_control:          assets_cache_control
			worker_read_timeout_ms:        worker_read_timeout_ms
			worker_restart_backoff_ms:     worker_restart_backoff_ms
			worker_restart_backoff_max_ms: worker_restart_backoff_max_ms
			worker_max_requests:           worker_max_requests
			worker_queue_capacity:         worker_queue_capacity
			worker_queue_timeout_ms:       worker_queue_timeout_ms
			workdir:                       workdir
		}
	}
}
