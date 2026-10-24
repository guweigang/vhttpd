module logging

import json2 as json
import log
import os
import sync
import time

// Event files retain their existing string-valued NDJSON contract.
pub fn RuntimeLogger.event_json(kind string, fields map[string]string) string {
	mut row := {
		'type': kind
		'ts':   '${time.now().unix()}'
	}
	for key, value in fields { row[key] = value }
	return json.encode(row, escape_unicode: true, time_as_unix: true)
}

pub fn RuntimeLogger.message_json(level log.Level, message string) string {
	return RuntimeLogger.event_json('runtime.log', {
		'level':   level.str()
		'message': message
		'pid':     '${os.getpid()}'
	})
}

fn write_stderr_record(data []u8) !int {
	mut stream := os.stderr()
	return stream.write(data)
}

// One mutex covers filtering and the complete record, including partial writes.
// The output is borrowed: switching logger never closes stderr or a caller's stream.
@[heap]
struct JsonLogger {
mut:
	mu       sync.Mutex
	level    log.Level      = .info
	write_fn fn ([]u8) !int = write_stderr_record
}

fn (l &JsonLogger) get_level() log.Level {
	l.mu.@lock()
	defer { l.mu.unlock() }
	return l.level
}

fn (mut l JsonLogger) set_level(level log.Level) {
	l.mu.@lock()
	l.level = level
	l.mu.unlock()
}

fn (mut l JsonLogger) set_always_flush(_ bool) {}

fn (mut l JsonLogger) free() { l.mu.destroy() }

fn (mut l JsonLogger) write(level log.Level, message string) {
	l.mu.@lock()
	defer { l.mu.unlock() }
	if int(l.level) < int(level) { return }
	data := (RuntimeLogger.message_json(level, message) + '\n').bytes()
	mut offset := 0
	for offset < data.len {
		n := l.write_fn(data[offset..]) or { return }
		if n <= 0 { return }
		offset += n
	}
}

fn (mut l JsonLogger) debug(message string) { l.write(.debug, message) }

fn (mut l JsonLogger) info(message string) { l.write(.info, message) }

fn (mut l JsonLogger) warn(message string) { l.write(.warn, message) }

fn (mut l JsonLogger) error(message string) { l.write(.error, message) }

fn (mut l JsonLogger) fatal(message string) {
	l.write(.fatal, message)
	panic(message)
}
