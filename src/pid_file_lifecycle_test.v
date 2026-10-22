module main

import config
import executor
import os
import net
import process_runtime
import server_lifecycle
import time

fn pid_lifecycle_root() string {
	return '/tmp/vhttpd-pid-lifecycle-${os.getpid()}-${time.now().unix_micro()}'
}

fn test_failed_bind_preflight_does_not_publish_or_overwrite_pid_file() {
	root := pid_lifecycle_root()
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut cfg := config.default_vhttpd_config()
	cfg.server.port = 0
	cfg.files.event_log = root + '/events'
	cfg.files.pid_file = root + '/server.pid'
	for existing in [false, true] {
		if existing { os.write_file(cfg.files.pid_file, 'other process') or { panic(err) } }
		mut rejected := false
		run_single_server([]string{}, cfg) or { rejected = true }
		assert rejected
		if existing {
			assert os.read_file(cfg.files.pid_file) or { panic(err) } == 'other process'
		} else {
			assert !os.exists(cfg.files.pid_file)
		}
	}
}

fn test_app_shutdown_does_not_release_process_owned_pid_file() {
	root := pid_lifecycle_root()
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	path := root + '/server.pid'
	mut files := process_runtime.PidFiles{}
	files.acquire([path]) or { panic(err) }
	mut app := &App{}
	cfg := server_lifecycle.ServerRuntimeConfig{
		pid_file:      path
		executor_plan: executor.LogicExecutorRuntimePlan{
			executor:  executor.DisabledLogicExecutor{}
			lifecycle: executor.disabled_executor_lifecycle()
		}
	}
	shutdown_app_runtime(mut app, cfg)
	shutdown_app_runtime(mut app, cfg)
	assert os.read_file(path) or { panic(err) } == '${os.getpid()}'
	files.close()
	assert !os.exists(path)
}

fn test_duplicate_start_reports_pid_file_conflict_before_constructing_app() {
	root := pid_lifecycle_root()
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	address := listener.addr() or { panic(err) }
	port := address.port() or { panic(err) }
	listener.close() or { panic(err) }
	mut cfg := config.default_vhttpd_config()
	cfg.server.host = '127.0.0.1'
	cfg.server.port = int(port)
	cfg.files.event_log = root + '/events'
	cfg.files.pid_file = root + '/server.pid'
	os.write_file(cfg.files.pid_file, 'keep') or { panic(err) }
	mut rejected := false
	run_single_server([]string{}, cfg) or {
		assert err.msg().contains('cannot acquire PID file')
		rejected = true
	}
	assert rejected
	assert os.read_file(cfg.files.pid_file) or { panic(err) } == 'keep'
}
