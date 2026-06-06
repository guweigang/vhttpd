module logging

import log
import os

pub struct RuntimeLogger {}

pub fn RuntimeLogger.default_level() log.Level {
	$if prod {
		return .warn
	}
	return .info
}

pub fn RuntimeLogger.parse_level(raw string) ?log.Level {
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

pub fn RuntimeLogger.effective_level() log.Level {
	if from_env := os.getenv_opt('VHTTPD_LOG_LEVEL') {
		if parsed := RuntimeLogger.parse_level(from_env) {
			return parsed
		}
	}
	return RuntimeLogger.default_level()
}

pub fn RuntimeLogger.configure() {
	mut local_logger := &log.Log{}
	local_logger.set_level(RuntimeLogger.effective_level())
	local_logger.set_local_time(true)
	log.set_logger(local_logger)
}
