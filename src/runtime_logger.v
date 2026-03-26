module main

import log
import os

fn runtime_default_log_level() log.Level {
	$if prod {
		return .warn
	}
	return .info
}

fn runtime_parse_log_level(raw string) ?log.Level {
	name := raw.trim_space().to_lower()
	return match name {
		'debug' { log.Level.debug }
		'info' { log.Level.info }
		'warn', 'warning' { log.Level.warn }
		'error' { log.Level.error }
		'fatal' { log.Level.fatal }
		else { none }
	}
}

fn runtime_effective_log_level() log.Level {
	if from_env := os.getenv_opt('VHTTPD_LOG_LEVEL') {
		if parsed := runtime_parse_log_level(from_env) {
			return parsed
		}
	}
	return runtime_default_log_level()
}

fn runtime_configure_logger() {
	mut local_logger := &log.Log{}
	local_logger.set_level(runtime_effective_log_level())
	local_logger.set_local_time(true)
	log.set_logger(local_logger)
}
