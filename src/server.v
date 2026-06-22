module main

// ═══════════════════════════════════════════════════════════════════════
// Lock Hierarchy (acquire in this order; NEVER acquire a lower lock while holding a higher one)
//
//   L0  app.mu                     — main mutex (providers, stats, event_log, general state)
//   L1  app.engines.primary.mu              — worker backend pool & queue
//   L2  app.websocket.state.mu              — WebSocket hub connections
//   L3  app.websocket.state.upstream_mu     — WebSocket provider/fixture state
//   L4  app.protocols.mcp.mu                 — MCP session manager
//   L5  app.providers.feishu.mu              — Feishu runtime state
//   L6  app.providers.feishu.card_bridge_mu  — Feishu card bridge clients
//   L7  app.providers.codex.mu               — Codex runtime state
//
// Independent (no ordering constraint with above):
//   app.websocket.state.send_mu             — WebSocket send serialization (short-lived, per-conn)
//   app.providers.feishu.card_bridge_send_mu — Feishu card bridge send serialization
//   app.providers.feishu.http_test_mu        — Feishu HTTP test stub (test-only)
//
// Rules:
//   - When acquiring multiple locks, always acquire higher (lower number) first.
//   - Use defer { mutex.unlock() } to ensure release on all paths.
//   - Never hold L0 while calling into user-provided callbacks (plugins, executors).
// ═══════════════════════════════════════════════════════════════════════
import config
import executor
import log
import os
import logging
import server_lifecycle
import upstream.transport

#include <time.h>
#include <signal.h>

fn C.tzset()
fn C.kill(pid int, sig int) int

__global (
	g_active_runtime_registry ActiveRuntimeRegistry
)

struct ActiveRuntimeRegistry {
mut:
	apps             []&App
	cfgs             []server_lifecycle.ServerRuntimeConfig
	is_shutting_down bool
}

fn (mut r ActiveRuntimeRegistry) register(app &App, cfg server_lifecycle.ServerRuntimeConfig) {
	r.apps << app
	r.cfgs << cfg
}

fn (mut r ActiveRuntimeRegistry) begin_shutdown() bool {
	if r.is_shutting_down {
		return false
	}
	r.is_shutting_down = true
	return true
}

fn (r ActiveRuntimeRegistry) shutting_down() bool {
	return r.is_shutting_down
}

fn (r ActiveRuntimeRegistry) config_snapshot() []server_lifecycle.ServerRuntimeConfig {
	return r.cfgs.clone()
}

fn register_active_runtime(app &App, cfg server_lifecycle.ServerRuntimeConfig) {
	unsafe {
		g_active_runtime_registry.register(app, cfg)
	}
}

fn begin_active_runtime_shutdown() bool {
	unsafe {
		return g_active_runtime_registry.begin_shutdown()
	}
}

fn active_runtime_is_shutting_down() bool {
	unsafe {
		return g_active_runtime_registry.shutting_down()
	}
}

fn active_runtime_config_snapshot() []server_lifecycle.ServerRuntimeConfig {
	unsafe {
		return g_active_runtime_registry.config_snapshot()
	}
}

fn vhttpd_signal_handler(sig os.Signal) {
	if !begin_active_runtime_shutdown() {
		return
	}

	log.info('[vhttpd] Received signal ${sig}. Cleaning up child process groups...')
	for pid in transport.get_child_pids() {
		if pid > 0 {
			log.info('[vhttpd] Terminating child process group: PID ${pid}')
			C.kill(-pid, 9)
		}
	}

	for cfg in active_runtime_config_snapshot() {
		os.rm(cfg.internal_admin_socket) or {}
		os.rm(cfg.pid_file) or {}
	}
	log.info('[vhttpd] Cleanup complete. Exiting process.')
	exit(128 + int(sig))
}

const vhttpd_version = '0.1.0'

const known_long_flags = [
	'--help',
	'--version',
	'--config',
	'--host',
	'--port',
	'--ssl-cert',
	'--ssl-key',
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
	'--vjsx-build-root',
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

// ── Global Lock Order ──
// When acquiring multiple locks, always follow this hierarchy to avoid deadlocks:
//   app.mu > app.providers.feishu.mu > app.websocket.state.mu > app.websocket.state.upstream_mu > app.upstreams.mu > app.protocols.mcp.mu > app.engines.primary.mu
// Any function that needs more than one lock MUST acquire them in the above order
// and release them in reverse order. Prefer defer for unlocks.
// Reviewers: reject PRs that introduce out-of-order locking.

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
	println('  --ssl-cert <path>            Enable HTTPS with this certificate')
	println('  --ssl-key <path>             Private key for --ssl-cert')
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
	println('  --executor <kind>            ${executor.builtin_executor_spec_kinds_label()}')
	println('  --php-bin <path>             PHP binary for generated php worker command')
	println('  --php-worker-entry <path>    PHP worker bootstrap script')
	println('  --php-app-entry <path>       PHP app/bootstrap entry (injects VHTTPD_APP)')
	println('  --php-extension <path>       PHP extension; repeat to add multiple entries')
	println('  --php-arg <value>            Extra PHP CLI arg; repeat to add multiple entries')
	println('  --vjsx-entry <path>          In-proc vjsx app entry (.js/.mjs/.ts/.mts)')
	println('  --vjsx-module-root <path>    Optional module root for in-proc vjsx')
	println('  --vjsx-build-root <path>     Optional .vjsxbuild root (defaults to /tmp cache)')
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

fn run_single_server(args []string, cfg config.VhttpdConfig) {
	runtime_cfg := server_lifecycle.ServerRuntimeConfig.resolve(args, cfg) or {
		log.error('server runtime config resolve failed: ${err}')
		return
	}
	preflight_server_bind(runtime_cfg) or {
		log.error('[vhttpd] ${err.msg()}')
		return
	}
	mut app := build_app_runtime(runtime_cfg.provider_settings, runtime_cfg.executor_plan, cfg,
		runtime_cfg.plan, runtime_cfg.app_build_cfg)
	register_active_runtime(app, runtime_cfg)
	defer {
		if !active_runtime_is_shutting_down() {
			shutdown_app_runtime(mut app, runtime_cfg)
		}
	}

	start_server_runtime(mut app, runtime_cfg)
	serve_server_runtime(mut app, runtime_cfg)
}

fn run_server(args []string) {
	cfg := config.load_vhttpd_config(args) or {
		log.error('config load failed: ${err}')
		return
	}
	configure_runtime_timezone(cfg.runtime.timezone)
	log.debug('[vhttpd] run_server: timezone configured')
	os.signal_ignore(.pipe)
	os.signal_opt(.int, vhttpd_signal_handler) or {
		log.error('[vhttpd] Failed to register SIGINT handler: ${err}')
	}
	os.signal_opt(.term, vhttpd_signal_handler) or {
		log.error('[vhttpd] Failed to register SIGTERM handler: ${err}')
	}
	if cfg.uses_multi_listener() {
		log.debug('[vhttpd] run_server: entering multi_server mode')
		run_multi_server(args, cfg)
		return
	}
	log.debug('[vhttpd] run_server: entering single_server mode')
	run_single_server(args, cfg)
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
	logging.RuntimeLogger.configure()
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
