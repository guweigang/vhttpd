module main

import net.http
import os

fn test_inproc_vjsx_executor_warmup_runs_app_startup_once() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_warmup_once_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'warmup-once.mts')
	os.write_file(app_file, '
let appStartupCount = 0;

const app = {
  async app_startup(runtime) {
    appStartupCount += 1;
    return [];
  },
  http(ctx) {
    return ctx.json({ appStartupCount }, 200);
  }
};

export default app;
') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
	})
	defer {
		executor.close()
	}
	mut app := App{}
	executor.warmup(mut app) or { panic(err) }
	executor.warmup(mut app) or { panic(err) }
	resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/warmup'
		req:         http.Request{
			method: .get
			url:    '/warmup'
			host:   'example.test'
		}
		remote_addr: '127.0.0.1'
		trace_id:    'trace_warmup_once'
		request_id:  'req_warmup_once'
	}) or { panic(err) }
	assert resp.response.status == 200
	assert resp.response.body.contains('"appStartupCount":1')
}

fn test_inproc_vjsx_executor_warmup_initializes_all_lane_hosts() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_warmup_all_lanes_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'warmup-all-lanes.mts')
	os.write_file(app_file, '
const app = {
  async app_startup(runtime) {
    return [];
  },
  http(ctx) {
    return ctx.json({ ok: true }, 200);
  }
};

export default app;
') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    2
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
	})
	defer {
		executor.close()
	}
	mut app := App{}
	executor.warmup(mut app) or { panic(err) }

	mut state := executor.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	assert state.hosts.len == 2
	assert state.hosts[0].initialized
	assert !isnil(state.hosts[0].session)
	assert state.hosts[1].initialized
	assert !isnil(state.hosts[1].session)
}
