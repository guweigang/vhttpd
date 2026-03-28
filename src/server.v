module main

import log
import os

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
	runtime_cfg := resolve_server_runtime_config(args, cfg) or {
		log.error('server runtime config resolve failed: ${err}')
		return
	}
	mut app := build_app_runtime(runtime_cfg.provider_settings, runtime_cfg.executor_plan,
		cfg, runtime_cfg.app_build_cfg)
	defer {
		shutdown_app_runtime(mut app, runtime_cfg)
	}

	start_server_runtime(mut app, runtime_cfg)
	serve_server_runtime(mut app, runtime_cfg)
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
