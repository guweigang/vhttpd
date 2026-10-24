module main

import json2 as json
import os
import time

fn test_app_events_and_worker_websocket_traces_share_one_event_sink() {
	root := os.join_path(os.temp_dir(), 'vhttpd-log-contract-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := root + '/events.ndjson'
	mut app := &App{ control_plane: ControlPlaneRuntime{ event_log: path } }
	app.emit('server.started', {
		'host': '127.0.0.1'
		'port': '8080'
	})
	app.emit('admin.started', {
		'host': '127.0.0.1'
		'port': '8081'
	})
	app.emit('http.request', {
		'status':        '503'
		'error_class':   'timeout'
		'response_mode': 'stream'
	})
	rt := app.build_websocket_runtime_context()
	fields := {
		'request_id':  'request'
		'trace_id':    'trace'
		'conn_id':     'connection'
		'payload_len': '3'
	}
	rt.trace('ws.message.enter', fields)
	assert 'label' !in fields
	rows := os.read_lines(path) or { panic(err) }
	assert rows.len == 4
	mut types := []string{}
	for line in rows {
		row := json.decode[map[string]string](line) or { panic(err) }
		types << row['type']
		assert row['ts'].i64() > 0
	}
	assert types == ['server.started', 'admin.started', 'http.request', 'runtime.trace']
	trace := json.decode[map[string]string](rows[3]) or { panic(err) }
	assert trace['label'] == 'ws.message.enter'
	assert trace['request_id'] == 'request'
	assert trace['trace_id'] == 'trace'
	assert trace['payload_len'] == '3'
	assert trace['pid'] == '${os.getpid()}'
	assert app.control_plane.http_stats.requests_total == 1
	assert app.control_plane.http_stats.errors_total == 1
	assert app.control_plane.http_stats.timeouts_total == 1
	assert app.control_plane.http_stats.streams_total == 1
	assert app.control_plane.http_stats.admin_actions_total == 1
}

fn test_disabled_or_failed_event_log_preserves_stats_and_releases_control_lock() {
	for path in ['', os.join_path(os.temp_dir(), 'no-log-parent-${time.sys_mono_now()}', 'events')] {
		mut control := ControlPlaneRuntime{ event_log: path }
		control.emit('http.request', {
			'status':      '504'
			'error_class': 'timeout'
		})
		assert control.mu.try_lock()
		control.mu.unlock()
		assert control.http_stats.requests_total == 1
		assert control.http_stats.errors_total == 1
		assert control.http_stats.timeouts_total == 1
	}
}
