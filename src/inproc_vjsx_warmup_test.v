module main

import executor
import net.http
import os
import time
import json2 as json

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
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
	})
	defer {
		exec.close()
	}
	mut app := InProcTestApp{}
	exec.warmup(mut app) or { panic(err) }
	exec.warmup(mut app) or { panic(err) }
	resp := exec.dispatch_http(mut app, executor.HttpLogicDispatchRequest{
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
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    2
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
	})
	defer {
		exec.close()
	}
	mut app := InProcTestApp{}
	exec.warmup(mut app) or { panic(err) }

	assert exec.lane_count() == 2
	assert exec.facade_snapshot().bootstrapped
	for lane in exec.lane_snapshot() {
		assert lane.healthy
		assert !lane.dirty
	}
}

fn wait_vjsx_job_marker(path string) string {
	for _ in 0 .. 250 {
		if result := os.read_file(path) {
			if result != '' {
				return result
			}
		}
		time.sleep(20 * time.millisecond)
	}
	panic('timed out waiting for scheduled job: ${path}')
}

fn test_inproc_vjsx_jobs_startup_overwrite_reload_and_shutdown() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_scheduled_jobs_${os.getpid()}')
	module_root := os.join_path(temp_dir, 'app')
	os.mkdir_all(module_root) or { panic(err) }
	defer { os.rmdir_all(temp_dir) or {} }
	app_file := os.join_path(module_root, 'app.mts')
	started := os.join_path(temp_dir, 'started')
	finished := os.join_path(temp_dir, 'finished')
	release := os.join_path(temp_dir, 'release')
	reloaded := os.join_path(temp_dir, 'reloaded')
	reload_finished := os.join_path(temp_dir, 'reload-finished')
	wrong := os.join_path(temp_dir, 'wrong')
	os.write_file(app_file, '
import { existsSync, writeFileSync } from "node:fs";
export default {
  async app_startup(runtime) {
    runtime.schedule("renew", 1, "wrong");
    await new Promise(resolve => setTimeout(resolve, 100));
    runtime.schedule("renew", 1, "renew");
    runtime.sessionStore("jobs").set("registeredAt", Date.now());
  },
  jobs: {
    wrong() {
      writeFileSync(${json.encode(wrong)}, "wrong");
    },
    async renew(runtime, name) {
      const ready = runtime.sessionStore("jobs");
      const start = ready.get("starts", 0) + 1;
      ready.set("starts", start);
      writeFileSync(${json.encode(started)}, name + ":" + start + ":" + (Date.now() - ready.get("registeredAt")));
      const deadline = Date.now() + 20000;
      while (!existsSync(${json.encode(release)})) {
        if (Date.now() >= deadline) throw new Error("job release timed out");
        await new Promise(resolve => setTimeout(resolve, 20));
      }
      writeFileSync(${json.encode(finished)}, name);
    }
  },
  http(ctx) { return ctx.json({ ok: true }); }
};') or { panic(err) }
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    2
		app_entry:       app_file
		module_root:     module_root
		runtime_profile: 'node'
		enable_fs:       true
	})
	defer { exec.close() }
	mut app := InProcTestApp{}
	exec.warmup(mut app) or { panic(err) }
	// Other lanes may still be warming after the app registers its schedule.
	// Check the first run against its registration time below.
	first_run := wait_vjsx_job_marker(started)
	first_parts := first_run.split(':')
	assert first_parts.len == 3
	assert first_parts[0] == 'renew'
	assert first_parts[1] == '1'
	assert first_parts[2].int() >= 1000
	time.sleep(1200 * time.millisecond)
	assert wait_vjsx_job_marker(started) == first_run
	assert !os.exists(wrong)

	os.write_file(app_file, '
import { writeFileSync } from "node:fs";
export function app_startup(runtime) {
  runtime.schedule("renew", 1, "renew");
}
export const jobs = {
  async renew(runtime, name) {
    writeFileSync(${json.encode(reloaded)}, name);
    await new Promise(resolve => setTimeout(resolve, 300));
    writeFileSync(${json.encode(reload_finished)}, name);
  }
};') or { panic(err) }
	os.write_file(release, 'release') or { panic(err) }
	assert wait_vjsx_job_marker(reloaded) == 'renew'
	assert wait_vjsx_job_marker(finished) == 'renew'
	assert wait_vjsx_job_marker(started) == first_run
	exec.close()
	assert os.read_file(reload_finished) or { panic(err) } == 'renew'
	os.rm(reloaded) or { panic(err) }
	time.sleep(1200 * time.millisecond)
	assert !os.exists(reloaded)
}
