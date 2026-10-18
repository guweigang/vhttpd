module executor

import time
import os
import vjsx

fn warmup_deadline_complete(exec InProcVjsxExecutor, mut control ExecutorTaskControl, boundary chan u64, delay time.Duration) {
	time.sleep(delay)
	boundary <- time.sys_mono_now()
	exec.finish_task(mut control)
}

fn test_warmup_bootstrap_can_outlive_hook_budget() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	defer { exec.close() }
	mut control := &ExecutorTaskControl{}
	boundary := chan u64{cap: 1}
	done := chan bool{cap: 1}
	mut state := exec.state
	state.mu.@lock()
	state.register_task_locked(mut control, '', false, done) or { panic(err) }
	state.mu.unlock()
	assert exec.begin_task(mut control, '')
	completion_worker := spawn warmup_deadline_complete(exec, mut control, boundary, 100 * time.millisecond)
	exec.await_lane_warmup(boundary, done, mut control, time.second, 50 * time.millisecond) or { panic(err) }
	completion_worker.wait()
	assert control.phase == .completed
}

fn test_warmup_deadlines_cancel_at_the_current_phase() {
	for bootstrapped in [false, true] {
		exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
		mut control := &ExecutorTaskControl{}
		boundary := chan u64{cap: 1}
		done := chan bool{cap: 1}
		if bootstrapped { boundary <- time.sys_mono_now() }
		mut rejected := false
		exec.await_lane_warmup(boundary, done, mut control, 5 * time.millisecond, 5 * time.millisecond) or {
			rejected = true
			assert err.msg() == if bootstrapped {
				'inproc_vjsx_executor_lane_warmup_timeout'
			} else {
				'inproc_vjsx_executor_lane_bootstrap_timeout'
			}
		}
		assert rejected
		assert control.phase == .cancelled
		exec.close()
	}
}

fn test_warmup_early_failure_and_already_completed_task_do_not_wait_for_bootstrap() {
	for failed in [false, true] {
		exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
		mut control := &ExecutorTaskControl{ phase: .completed }
		if failed { control.reason = 'module_import_failed' }
		boundary := chan u64{cap: 1}
		done := chan bool{cap: 1}
		done <- true
		mut rejected := false
		exec.await_lane_warmup(boundary, done, mut control, time.second, time.second) or {
			rejected = true
			assert err.msg() == 'module_import_failed'
		}
		assert rejected == failed
		exec.close()
	}
}

fn test_hook_deadline_interrupts_running_warmup_and_releases_lane_on_close() {
	root := os.join_path(os.temp_dir(), 'vhttpd-warmup-hook-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	entry := os.join_path(root, 'app.mjs')
	os.write_file(entry, 'export const ready = true;') or { panic(err) }
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1, app_entry: entry, module_root: root, runtime_profile: 'script' })
	defer { exec.close() }
	exec.ensure_lane_host(0) or { panic(err) }
	session := exec.state.hosts[0].session_handle() or { panic('missing session') }
	entered := chan bool{cap: 1}
	ctx := session.context()
	ctx.install_host_api(vjsx.HostApiConfig{
		globals: [vjsx.HostGlobalBinding{
			name:  '__warmup_hook_entered'
			value: fn [entered] (ctx &vjsx.Context) vjsx.Value {
				return ctx.js_function(fn [ctx, entered] (_args []vjsx.Value) vjsx.Value {
					entered <- true
					return ctx.js_undefined()
				})
			}
		}]
	})
	binding := ctx.eval('globalThis.__vhttpd_startup_handle = function () { __warmup_hook_entered(); while (true) {} };') or { panic(err) }
	binding.free()
	mut slot := &InProcVjsxLaneWarmupTaskSlot{}
	done := chan bool{cap: 1}
	exec.submit_warmup_task(exec.state.lane_workers[0], InProcVjsxLaneWarmupTask{ app: NoOpAppFacade{}, slot: slot, done: done }) or { panic(err) }
	select {
		_ := <-entered {
		}
		3 * time.second {
			panic('startup hook did not enter')
		}
	}
	mut timed_out := false
	exec.await_lane_warmup(slot.bootstrapped, done, mut slot.control, time.second, 5 * time.millisecond) or {
		timed_out = true
		assert err.msg() == 'inproc_vjsx_executor_lane_warmup_timeout'
	}
	assert timed_out
	exec.close()
	assert session.is_closed()
	assert slot.control.phase == .cancelled
	assert exec.state.tasks.len == 0
	assert exec.state.lanes[0].inflight == 0
}

fn test_warmup_observer_does_not_refresh_elapsed_hook_budget() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	defer { exec.close() }
	mut control := &ExecutorTaskControl{}
	boundary := chan u64{cap: 1}
	done := chan bool{cap: 1}
	// A phase already one second old cannot receive another hook timeout.
	boundary <- time.sys_mono_now() - u64(time.second)
	mut expired := false
	exec.await_lane_warmup(boundary, done, mut control, time.second, time.millisecond) or {
		expired = true
		assert err.msg() == 'inproc_vjsx_executor_lane_warmup_timeout'
	}
	assert expired
	assert control.phase == .cancelled
}
