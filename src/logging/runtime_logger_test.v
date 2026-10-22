module logging

import json2 as json
import log
import os

@[heap]
struct LogOutput {
mut:
	data []u8
}

fn test_json_logger_preserves_message_and_filters_without_text_prefix() {
	mut output := &LogOutput{}
	mut logger := JsonLogger{
		level:    .warn
		write_fn: fn [mut output] (data []u8) !int {
			output.data << data
			return data.len
		}
	}
	logger.info('hidden')
	logger.warn('日志 "quoted"\nsecond line\\tail')
	logger.error('failure')
	lines := output.data.bytestr().split_into_lines()
	assert lines.len == 2
	row := json.decode[map[string]string](lines[0]) or { panic(err) }
	assert row['type'] == 'runtime.log'
	assert row['level'] == 'warn'
	assert row['message'] == '日志 "quoted"\nsecond line\\tail'
	assert row['pid'] == '${os.getpid()}'
	assert row['ts'].i64() > 0
	size := output.data.len
	logger.set_level(.disabled)
	assert logger.get_level() == .disabled
	logger.error('hidden too')
	assert output.data.len == size
}

fn test_event_json_keeps_existing_envelope_and_fields() {
	row := json.decode[map[string]string](RuntimeLogger.event_json('server.started', {
		'host':     '127.0.0.1'
		'port':     '8080'
		'trace_id': 'trace'
	})) or { panic(err) }
	assert row['type'] == 'server.started'
	assert row['ts'].i64() > 0
	assert row['port'] == '8080'
	assert row['trace_id'] == 'trace'
}

fn test_log_level_aliases_and_invalid_value() {
	assert RuntimeLogger.parse_level(' WARNING ') or { panic('missing warn') } == log.Level.warn
	assert RuntimeLogger.parse_level('debug') or { panic('missing debug') } == log.Level.debug
	assert RuntimeLogger.parse_level('invalid') == none
}

fn test_json_logger_finishes_partial_writes_and_serializes_concurrent_records() {
	mut output := &LogOutput{}
	mut logger := &JsonLogger{
		level:    .info
		write_fn: fn [mut output] (data []u8) !int {
			n := if data.len > 3 { 3 } else { data.len }
			output.data << data[..n]
			return n
		}
	}
	done := chan bool{cap: 8}
	for idx in 0 .. 8 {
		spawn fn [mut logger, done, idx] () {
			for n in 0 .. 8 { logger.info('${idx}/${n}') }
			done <- true
		}()
	}
	for _ in 0 .. 8 { _ := <-done }
	lines := output.data.bytestr().split_into_lines()
	assert lines.len == 64
	mut seen := map[string]bool{}
	for line in lines {
		row := json.decode[map[string]string](line) or { panic(err) }
		seen[row['message']] = true
	}
	for idx in 0 .. 8 {
		for n in 0 .. 8 {
			assert seen['${idx}/${n}']
		}
	}
}

fn test_default_log_level_still_differs_between_development_and_production() {
	$if prod {
		assert RuntimeLogger.default_level() == log.Level.warn
	} $else {
		assert RuntimeLogger.default_level() == log.Level.info
	}
}

fn test_json_format_is_opt_in_and_invalid_values_fall_back_to_text() {
	previous := os.getenv_opt('VHTTPD_LOG_FORMAT')
	defer {
		if value := previous {
			os.setenv('VHTTPD_LOG_FORMAT', value, true)
		} else {
			os.unsetenv('VHTTPD_LOG_FORMAT')
		}
	}
	for value in ['', 'text', 'invalid'] {
		os.setenv('VHTTPD_LOG_FORMAT', value, true)
		assert !RuntimeLogger.json_enabled()
	}
	os.setenv('VHTTPD_LOG_FORMAT', ' JSON ', true)
	assert RuntimeLogger.json_enabled()
}
