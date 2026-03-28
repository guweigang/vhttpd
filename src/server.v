module main

import log
import os
import time
import veb
import veb.request_id

#include <time.h>

fn C.tzset()

const vhttpd_version = '0.1.0'

const known_long_flags = [
	'--help',
	'--version',
	'--config',
	'--host',
	'--port',
	'--event-log',
	'--pid-file',
	'--worker-read-timeout-ms',
	'--worker-cmd',
	'--worker-autostart',
	'--worker-restart-backoff-ms',
	'--worker-restart-backoff-max-ms',
	'--worker-max-requests',
	'--worker-queue-capacity',
	'--worker-queue-timeout-ms',
	'--worker-socket',
	'--worker-sockets',
	'--worker-pool-size',
	'--worker-socket-prefix',
	'--executor',
	'--php-bin',
	'--php-worker-entry',
	'--php-app-entry',
	'--php-extension',
	'--php-arg',
	'--vjsx-entry',
	'--vjsx-module-root',
	'--vjsx-signature-root',
	'--vjsx-signature-include',
	'--vjsx-signature-exclude',
	'--vjsx-runtime-profile',
	'--vjsx-thread-count',
	'--admin-host',
	'--admin-port',
	'--admin-token',
	'--feishu-enabled',
	'--feishu-app-id',
	'--feishu-app-secret',
	'--feishu-open-base-url',
	'--ollama-enabled',
]

fn has_flag(args []string, flags []string) bool {
	for a in args {
		for f in flags {
			if a == f {
				return true
			}
		}
	}
	return false
}

fn print_vhttpd_help() {
	println('vhttpd ${vhttpd_version}')
	println('')
	println('Usage:')
	println('  vhttpd [--config <file.toml>] [options]')
	println('  vhttpd <file.toml>')
	println('')
	println('Common options:')
	println('  --help, -h')
	println('  --version, -v')
	println('  --config <path>              TOML config file')
	println('  --host <host>                Data plane host')
	println('  --port <port>                Data plane port')
	println('  --admin-host <host>          Admin plane host')
	println('  --admin-port <port>          Admin plane port')
	println('  --admin-token <token>        Admin API token')
	println('  --event-log <path>           Event log path')
	println('  --pid-file <path>            PID file path')
	println('  --worker-autostart <0|1>')
	println('  --worker-cmd <command>')
	println('  --worker-socket <path>       Worker socket path; when pool-size > 1 it is used as the socket stem')
	println('  --worker-pool-size <N>       Managed worker pool size')
	println('  --worker-queue-capacity <N>  Max waiting requests before immediate 503')
	println('  --worker-queue-timeout-ms <N> Max wait time for a worker before 504')
	println('  --worker-socket-prefix <p>   Advanced override for pool socket prefix')
	println('  --executor <kind>            ${builtin_logic_executor_kinds_label()}')
	println('  --php-bin <path>             PHP binary for generated php worker command')
	println('  --php-worker-entry <path>    PHP worker bootstrap script')
	println('  --php-app-entry <path>       PHP app/bootstrap entry (injects VHTTPD_APP)')
	println('  --php-extension <path>       PHP extension; repeat to add multiple entries')
	println('  --php-arg <value>            Extra PHP CLI arg; repeat to add multiple entries')
	println('  --vjsx-entry <path>          In-proc vjsx app entry (.js/.mjs/.ts/.mts)')
	println('  --vjsx-module-root <path>    Optional module root for in-proc vjsx')
	println('  --vjsx-signature-root <path> Optional source signature root (defaults to module root)')
	println('  --vjsx-signature-include <g> Comma-separated include globs for source signature')
	println('  --vjsx-signature-exclude <g> Comma-separated exclude globs for source signature')
	println('  --vjsx-runtime-profile <p>   script | node')
	println('  --vjsx-thread-count <N>      In-proc vjsx lane count')
	println('  --feishu-enabled <0|1>')
	println('  --feishu-app-id <id>')
	println('  --feishu-app-secret <secret>')
	println('  --feishu-open-base-url <url>')
	println('')
	println('Examples:')
	println('  vhttpd --config /path/to/vhttpd.toml')
	println('  vhttpd /path/to/vhttpd.toml')
}

fn validate_args(args []string) ! {
	for arg in args {
		if arg.len == 0 {
			continue
		}
		if arg == '-h' || arg == '-v' {
			continue
		}
		if arg.starts_with('--') {
			key := if arg.contains('=') { arg.all_before('=') } else { arg }
			if key in known_long_flags {
				continue
			}
			return error('unknown option: ${arg}')
		}
		if arg.starts_with('-') {
			return error('unknown option: ${arg}')
		}
		// positional args are allowed (e.g. config path shorthand)
	}
}

fn run_server(args []string) {
	cfg := load_vhttpd_config(args) or {
		log.error('config load failed: ${err}')
		return
	}
	configure_runtime_timezone(cfg.runtime.timezone)
	os.signal_ignore(.pipe)
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
		cfg.worker.env.clone()) or {
		log.error('executor runtime plan resolve failed: ${err}')
		return
	}
	workdir := os.getwd()
	internal_admin_socket := prepare_server_runtime_files(event_log, pid_file) or {
		log.error('server runtime file setup failed: ${err}')
		return
	}
	mut app := build_app_runtime(provider_settings, executor_plan, cfg, AppRuntimeBuildConfig{
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
	})
	defer {
		app.emit('server.stopped', {
			'pid': '${os.getpid()}'
		})
		executor_plan.lifecycle.stop(mut app)
		// Graceful provider shutdown is now spec/runtime-driven.
		app.stop_all_providers()
		os.rm(internal_admin_socket) or {}
		os.rm(pid_file) or {}
	}

	initialize_app_runtime(mut app, internal_admin_socket)
	executor_plan.lifecycle.start(mut app)
	mount_app_assets(mut app)
	install_app_middleware(mut app)
	emit_server_started_event(mut app, host, port, admin_enabled, admin_host, admin_port)
	start_admin_plane(mut app, admin_enabled, admin_host, admin_port, admin_token)
	start_upstream_providers(mut app)
	log_server_runtime_endpoints(app, host, port)

	veb.run_at[App, Context](mut app,
		host:                 host
		port:                 port
		family:               .ip
		show_startup_message: false
	) or {
		err_msg := err.msg()
		app.emit('server.failed', {
			'pid':   '${os.getpid()}'
			'error': err_msg
		})
		log.error('server failed: ${err_msg}')
	}
}

fn configure_runtime_timezone(config_tz string) {
	mut tz := config_tz.trim_space()
	if tz == '' {
		tz = os.getenv_opt('VHTTPD_TZ') or { '' }
	}
	if tz.trim_space() == '' {
		tz = os.getenv_opt('TZ') or { '' }
	}
	if tz.trim_space() == '' {
		tz = 'Asia/Shanghai'
	}
	os.setenv('TZ', tz, true)
	C.tzset()
	runtime_configure_logger()
	log.info('vhttpd timezone: ${tz}')
}

fn main() {
	args := os.args[1..]
	if has_flag(args, ['--help', '-h']) {
		print_vhttpd_help()
		return
	}
	if has_flag(args, ['--version', '-v']) {
		println(vhttpd_version)
		return
	}
	validate_args(args) or {
		eprintln('argument error: ${err}')
		eprintln('run `vhttpd --help` for usage.')
		exit(2)
	}
	run_server(args)
}
