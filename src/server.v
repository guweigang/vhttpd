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
import process_runtime
import sync
import time

#include <time.h>
#include <signal.h>

fn C.tzset()

__global (
	g_active_runtime_registry ActiveRuntimeRegistry
)

struct ActiveRuntimeRegistry {
mut:
	mu               sync.Mutex
	apps             []&App
	cfgs             []server_lifecycle.ServerRuntimeConfig
	is_shutting_down bool
}

fn (mut r ActiveRuntimeRegistry) register(app &App, cfg server_lifecycle.ServerRuntimeConfig) {
	r.mu.@lock()
	defer { r.mu.unlock() }
	if r.is_shutting_down { return }
	r.apps << app
	r.cfgs << cfg
}

fn (mut r ActiveRuntimeRegistry) begin_shutdown() bool {
	r.mu.@lock()
	defer { r.mu.unlock() }
	if r.is_shutting_down {
		return false
	}
	r.is_shutting_down = true
	return true
}

fn (r &ActiveRuntimeRegistry) shutting_down() bool {
	r.mu.@lock()
	defer { r.mu.unlock() }
	return r.is_shutting_down
}

// Stop admission and notify every App before waiting for any background task.
// Keep executors/workers alive until already claimed callbacks have returned.
fn (mut r ActiveRuntimeRegistry) stop_runtime_transports() {
	r.mu.@lock()
	mut apps := r.apps.clone()
	r.mu.unlock()
	for stopped in stop_app_transports(mut apps) {
		if stopped.failure != '' { log.error('Transport shutdown failed: ${stopped.failure}') }
	}
}

fn (mut r ActiveRuntimeRegistry) shutdown_apps() ! {
	r.mu.@lock()
	mut bindings := []RuntimeShutdownBinding{cap: r.apps.len}
	for index, app in r.apps { bindings << RuntimeShutdownBinding{app: app, cfg: r.cfgs[index]} }
	r.mu.unlock()
	shutdown_runtime_bindings(bindings)!
}

fn (r &ActiveRuntimeRegistry) config_snapshot() []server_lifecycle.ServerRuntimeConfig {
	r.mu.@lock()
	defer { r.mu.unlock() }
	return r.cfgs.clone()
}

fn (r &ActiveRuntimeRegistry) listener_summaries() []executor.AdminListenerRuntimeSummary {
	r.mu.@lock()
	apps := r.apps.clone()
	cfgs := r.cfgs.clone()
	r.mu.unlock()
	mut summaries := []executor.AdminListenerRuntimeSummary{cap: apps.len}
	for i, app in apps {
		cfg := cfgs[i] or { continue }
		pipelines := app.admin_pipeline_runtime_snapshot()
		app.control_plane.mu.@lock()
		metrics := app.control_plane.http_observations.total
		mut route_metrics := []executor.AdminHttpRouteMetrics{}
		mut ids := app.control_plane.http_observations.routes.keys()
		ids.sort()
		for id in ids { route_metrics << executor.AdminHttpRouteMetrics{pipeline_id: id, metrics: app.control_plane.http_observations.routes[id]} }
		errors := app.control_plane.http_observations.errors.clone()
		app.control_plane.mu.unlock()
		summaries << executor.AdminListenerRuntimeSummary{
			listener_id: cfg.plan_listener_id
			site_id:     cfg.site_id
			host:        cfg.host
			port:        cfg.port
			pipelines:   pipelines
			is_control: !cfg.serve_data_plane
			http_metrics: metrics
			route_metrics: route_metrics
			recent_errors: errors
		}
	}
	return summaries
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

fn active_runtime_listener_summaries() []executor.AdminListenerRuntimeSummary {
	unsafe {
		return g_active_runtime_registry.listener_summaries()
	}
}

fn vhttpd_shutdown_runtime(sig os.Signal) {
	if !begin_active_runtime_shutdown() {
		return
	}

	log.info('[vhttpd] Received signal ${sig}. Cleaning up child process groups...')
	unsafe { g_active_runtime_registry.shutdown_apps() or { log.error('App signal shutdown failed: ${err}') } }
	process_runtime.shutdown_managed_processes()

	process_runtime.close_pid_files()
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

fn run_single_server(args []string, cfg config.VhttpdConfig) ! {
	runtime_cfg := server_lifecycle.ServerRuntimeConfig.resolve(args, cfg) or {
		log.error('server runtime config resolve failed: ${err}')
		return err
	}
	run_single_server_with_config(cfg, runtime_cfg)!
}

fn run_single_server_with_config(cfg config.VhttpdConfig, runtime_cfg server_lifecycle.ServerRuntimeConfig) ! {
	mut transferred := false
	defer { if !transferred { runtime_cfg.executor_plan.executor.close() } }
	preflight_server_bind(runtime_cfg) or {
		log.error('[vhttpd] ${err.msg()}')
		return err
	}
	process_runtime.acquire_pid_files([runtime_cfg.pid_file]) or {
		log.error('[vhttpd] ${err.msg()}')
		return err
	}
	defer { process_runtime.close_pid_files() }
	mut app := build_app_runtime(runtime_cfg.provider_settings, runtime_cfg.executor_plan, cfg,
		runtime_cfg.plan, runtime_cfg.app_build_cfg)
	transferred = true
	register_active_runtime(app, runtime_cfg)
	defer {
		if !active_runtime_is_shutting_down() {
			shutdown_app_runtime(mut app, runtime_cfg)
		}
	}

	start_server_runtime(mut app, runtime_cfg)
	serve_server_runtime(mut app, runtime_cfg)
	wait_for_active_runtime_shutdown()
}

fn run_server(args []string) ! {
	cfg := config.load_vhttpd_config(args) or {
		log.error('config load failed: ${err}')
		return err
	}
	configure_runtime_timezone(runtime_timezone_from_plan_or_config(args, cfg))
	log.debug('[vhttpd] run_server: timezone configured')
	os.signal_ignore(.pipe)
	process_runtime.install_shutdown_signal_handler(vhttpd_shutdown_runtime)!
	defer {
		process_runtime.shutdown_managed_processes()
		process_runtime.close_pid_files()
	}
	if should_run_multi_server(args, cfg) {
		log.debug('[vhttpd] run_server: entering multi_server mode')
		run_multi_server(args, cfg)!
		return
	}
	log.debug('[vhttpd] run_server: entering single_server mode')
	run_single_server(args, cfg)!
}

fn should_run_multi_server(args []string, cfg config.VhttpdConfig) bool {
	if cfg.uses_multi_listener() {
		return true
	}
	plan := config.load_runtime_plan_or_compile_config(args, cfg) or { return false }
	return plan.listeners.len > 1
}

fn runtime_timezone_from_plan_or_config(args []string, cfg config.VhttpdConfig) string {
	plan := config.load_runtime_plan_or_compile_config(args, cfg) or { return cfg.runtime.timezone }
	return if plan.server.timezone.trim_space() != '' {
		plan.server.timezone
	} else {
		cfg.runtime.timezone
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
	logging.RuntimeLogger.configure()
	log.info('vhttpd timezone: ${tz}')
}

fn main() {
	// Configuration errors precede timezone setup; honor explicit JSON output there too.
	if logging.RuntimeLogger.json_enabled() { logging.RuntimeLogger.configure() }
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
	run_server(args) or { exit(1) }
}

// HTTP shutdown makes serving return before the signal worker finishes cleanup.
// Keep the main routine alive until that worker exits the process with 128+sig.
fn wait_for_active_runtime_shutdown() {
	for active_runtime_is_shutting_down() { time.sleep(time.millisecond) }
}
