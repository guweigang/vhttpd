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

	os.mkdir_all(os.dir(event_log)) or {}
	os.mkdir_all(os.dir(pid_file)) or {}
	os.write_file(pid_file, '${os.getpid()}') or {}
	internal_admin_socket := default_internal_admin_socket()

	mut app := &App{
		event_log:                                event_log
		started_at_unix:                          time.now().unix()
		worker_backend:                           WorkerBackendRuntime{
			backend:                PhpWorkerBackend{}
			sockets:                executor_plan.bootstrap.worker_sockets
			read_timeout_ms:        worker_read_timeout_ms
			autostart:              executor_plan.bootstrap.worker_autostart
			cmd:                    executor_plan.bootstrap.worker_cmd
			env:                    executor_plan.bootstrap.worker_env
			workdir:                workdir
			restart_backoff_ms:     worker_restart_backoff_ms
			restart_backoff_max_ms: worker_restart_backoff_max_ms
			max_requests:           worker_max_requests
			queue_capacity:         worker_queue_capacity
			queue_timeout_ms:       worker_queue_timeout_ms
			queue_poll_ms:          10
		}
		worker_backend_mode:                      executor_plan.worker_backend_mode
		logic_executor:                           executor_plan.executor
		logic_executor_lifecycle:                 executor_plan.lifecycle.name()
		internal_admin_socket:                    internal_admin_socket
		stream_dispatch:                          executor_plan.bootstrap.stream_dispatch
		websocket_dispatch_mode:                  executor_plan.bootstrap.websocket_dispatch_mode
		admin_on_data_plane:                      !admin_enabled
		admin_token:                              admin_token
		assets_enabled:                           assets_enabled
		assets_prefix:                            assets_prefix
		assets_root:                              assets_root
		assets_root_real:                         assets_root_real
		assets_cache_control:                     assets_cache_control
		mcp_max_sessions:                         if cfg.mcp.max_sessions > 0 {
			cfg.mcp.max_sessions
		} else {
			1000
		}
		mcp_max_pending_messages:                 if cfg.mcp.max_pending_messages > 0 {
			cfg.mcp.max_pending_messages
		} else {
			128
		}
		mcp_session_ttl_seconds:                  if cfg.mcp.session_ttl_seconds > 0 {
			cfg.mcp.session_ttl_seconds
		} else {
			900
		}
		mcp_sampling_capability_policy:           normalize_mcp_sampling_capability_policy(cfg.mcp.sampling_capability_policy)
		mcp_allowed_origins:                      cfg.mcp.allowed_origins.clone()
		feishu_enabled:                           provider_settings.feishu.enabled
		feishu_open_base_url:                     provider_settings.feishu.open_base_url
		feishu_reconnect_delay_ms:                provider_settings.feishu.reconnect_delay_ms
		feishu_token_refresh_skew_seconds:        provider_settings.feishu.token_refresh_skew_seconds
		feishu_recent_event_limit:                provider_settings.feishu.recent_event_limit
		websocket_upstream_recent_dispatch_limit: 50
		feishu_apps:                              provider_settings.feishu.apps.clone()
		upstream_sessions:                        map[string]UpstreamRuntimeSession{}
		mcp_sessions:                             map[string]McpSession{}
		ws_hub_conns:                             map[string]HubConn{}
		ws_hub_room_members:                      map[string]map[string]bool{}
		ws_hub_conn_rooms:                        map[string]map[string]bool{}
		ws_hub_conn_meta:                         map[string]map[string]string{}
		ws_hub_pending:                           map[string][]HubPendingMessage{}
		feishu_runtime:                           map[string]FeishuProviderRuntime{}
		providers:                                ProviderHost{
			registry: map[string]Provider{}
			specs:    map[string]ProviderSpec{}
		}
		ollama_enabled:                           provider_settings.ollama_enabled
		fixture_websocket_runtime:                map[string]FixtureWebSocketUpstreamRuntime{}
		websocket_upstream_recent_activities:     []WebSocketUpstreamActivitySnapshot{}
		// codex upstream
		codex_runtime:  CodexProviderRuntime{
			enabled:             provider_settings.codex.enabled
			url:                 provider_settings.codex.url
			model:               provider_settings.codex.model
			effort:              provider_settings.codex.effort
			cwd:                 provider_settings.codex.cwd
			approval_policy:     provider_settings.codex.approval_policy
			sandbox:             provider_settings.codex.sandbox
			reconnect_delay_ms:  provider_settings.codex.reconnect_delay_ms
			flush_interval_ms:   provider_settings.codex.flush_interval_ms
			pending_rpcs:        map[int]CodexPendingRpc{}
			stream_map:          map[string][]CodexTarget{}
			err_bursts:          map[string][]string{}
			err_pending_flushes: map[string]bool{}
			thread_stream_map:   map[string]string{}
		}
		feishu_buffers: map[string]FeishuStreamBuffer{}
	}
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

	app.worker_backend.env['VHTTPD_INTERNAL_ADMIN_SOCKET'] = internal_admin_socket
	go run_internal_admin_server(mut app, internal_admin_socket)
	if app.feishu_enabled {
		go app.feishu_runtime_run_buffer_flusher()
	}
	bootstrap_providers(mut app)

	executor_plan.lifecycle.start(mut app)
	if app.assets_enabled && app.assets_root_real != '' {
		app.mount_static_folder_at(app.assets_root_real, app.assets_prefix) or {
			log.error('assets mount failed: ${err}')
		}
	}

	app.use(request_id.middleware[Context](request_id.Config{
		header:    'X-Request-ID'
		generator: fn () string {
			return 'req-${time.now().unix_micro()}'
		}
	}))
	if app.assets_enabled && app.assets_cache_control.trim_space() != '' {
		assets_prefix_mw := app.assets_prefix
		cache_control := app.assets_cache_control
		app.use(
			handler: fn [assets_prefix_mw, cache_control] (mut ctx Context) bool {
				mut url := ctx.req.url
				if q := url.index('?') {
					url = url[..q]
				}
				if url == assets_prefix_mw || url.starts_with('${assets_prefix_mw}/') {
					ctx.set_custom_header('cache-control', cache_control) or {}
				}
				return true
			}
		)
	}
	app.emit('server.started', {
		'host':                     host
		'port':                     '${port}'
		'pid':                      '${os.getpid()}'
		'worker_backend':           app.worker_backend.kind()
		'worker_backend_mode':      '${app.worker_backend_mode}'
		'logic_executor':           app.logic_executor_kind()
		'logic_executor_lifecycle': app.logic_executor_lifecycle
		'logic_executor_model':     '${app.logic_executor_model()}'
		'logic_provider':           app.logic_executor_provider()
		'worker_autostart':         if app.worker_backend.autostart { 'true' } else { 'false' }
		'worker_pool_size':         '${app.worker_backend.sockets.len}'
		'admin_enabled':            if admin_enabled { 'true' } else { 'false' }
		'admin_host':               if admin_enabled { admin_host } else { '' }
		'admin_port':               if admin_enabled { '${admin_port}' } else { '' }
	})
	if admin_enabled {
		go run_admin_server(mut app, admin_host, admin_port, admin_token)
		app.emit('admin.started', {
			'host': admin_host
			'port': '${admin_port}'
		})
		log.info('[vhttpd] Control Plane (admin): http://${admin_host}:${admin_port}/admin')
	} else {
		log.info('[vhttpd] Control Plane (admin): disabled (served on Data Plane /admin)')
	}
	mut upstream_launches := app.provider_runtime_upstream_launches()
	mut feishu_labels := []string{}
	mut started_any_upstream := false
	for launch in upstream_launches {
		if launch.instance == '' {
			if launch.provider == 'feishu' && launch.label != '' {
				feishu_labels = launch.label.split(', ').clone()
			}
			continue
		}
		started_any_upstream = true
		go run_websocket_upstream_provider(mut app, launch.provider, launch.instance)
		if launch.provider == 'codex' {
			log.info('[vhttpd] WebSocket Upstream: codex enabled (${launch.url})')
		}
	}
	if feishu_labels.len > 0 {
		log.info('[vhttpd] WebSocket Upstream: feishu enabled (${feishu_labels.join(', ')})')
	}
	if !started_any_upstream {
		log.info('[vhttpd] WebSocket Upstream: disabled')
	}
	if app.assets_enabled && app.assets_root_real != '' {
		log.info('[vhttpd] Assets: ${app.assets_prefix} -> ${app.assets_root_real}')
	} else {
		log.info('[vhttpd] Assets: disabled')
	}
	log.info('[vhttpd] Data Plane: http://${host}:${port}/')

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
