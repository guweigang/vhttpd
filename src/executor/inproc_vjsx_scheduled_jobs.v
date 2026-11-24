module executor

import log
import time
import x.scheduler

struct VjsxScheduledJob {
	name             string
	interval_seconds int
	handler          string
}

@[heap]
struct VjsxJobSchedule {
	source_signature string
mut:
	scheduler   scheduler.Scheduler
	due         []VjsxScheduledJob
	started_at  u64
	last_second i64
}

fn new_vjsx_job_schedule(source_signature string, jobs []VjsxScheduledJob) ?&VjsxJobSchedule {
	if jobs.len == 0 {
		return none
	}
	mut schedule := &VjsxJobSchedule{ source_signature: source_signature }
	// Prime x.scheduler's first tick without dispatching any jobs. Drive
	// subsequent ticks with elapsed monotonic seconds so wall time changes
	// and activation partway through a second cannot advance the first run.
	for job in jobs {
		schedule.scheduler.every(job.name, time.second * i64(job.interval_seconds), fn [mut schedule, job] () {
			schedule.due << job
		})
	}
	schedule.scheduler.run_pending(max_i32)
	schedule.due.clear()
	schedule.started_at = time.sys_mono_now()
	return schedule
}

// The signature refresh thread is the sole driver of a published scheduler.
fn (e InProcVjsxExecutor) tick_scheduled_jobs() {
	mut state := e.state
	state.mu.@lock()
	mut schedule := state.job_schedule or {
		state.mu.unlock()
		return
	}
	reload := schedule.source_signature != state.cached_source_signature
	state.mu.unlock()
	elapsed_seconds := i64((time.sys_mono_now() - schedule.started_at) / u64(time.second))
	if elapsed_seconds <= schedule.last_second {
		return
	}
	schedule.last_second = elapsed_seconds
	if reload {
		e.start_scheduled_job(schedule, none)
		return
	}
	schedule.scheduler.run_pending(i64(max_i32) + elapsed_seconds)
	for job in schedule.due {
		e.start_scheduled_job(schedule, job)
	}
	schedule.due.clear()
}

fn (e InProcVjsxExecutor) start_scheduled_job(schedule &VjsxJobSchedule, job ?VjsxScheduledJob) {
	mut state := e.state
	state.mu.@lock()
	current := state.job_schedule or {
		state.mu.unlock()
		return
	}
	if state.stopping || voidptr(current) != voidptr(schedule) {
		state.mu.unlock()
		return
	}
	// An empty name reserves the worker that reloads the app after a source change.
	name := if definition := job { definition.name } else { '' }
	if name in state.running_jobs {
		state.mu.unlock()
		return
	}
	app := state.app_ref or {
		state.mu.unlock()
		return
	}
	state.running_jobs[name] = true
	state.mu.unlock()
	spawn e.run_scheduled_job(app, schedule, name, job)
}

fn (e InProcVjsxExecutor) run_scheduled_job(app_ref EmbeddedHost, schedule &VjsxJobSchedule, name string, job ?VjsxScheduledJob) {
	mut state := e.state
	defer {
		state.mu.@lock()
		state.running_jobs.delete(name)
		state.mu.unlock()
	}
	mut app := app_ref
	e.dispatch_scheduled_job(mut app, schedule, job) or {
		log.warn('[vhttpd] vjsx scheduled dispatch failed app=${e.facade_snapshot().config.app_entry} job=${name}: ${err.msg()}')
	}
}

fn (e InProcVjsxExecutor) dispatch_scheduled_job(mut app EmbeddedHost, schedule &VjsxJobSchedule, job ?VjsxScheduledJob) ! {
	lane := e.acquire_next_lane(inproc_vjsx_lane_wait_timeout_ms)!
	defer { e.release_lane(lane.id) }
	idx := e.lane_index_by_id(lane.id)
	e.ensure_lane_host(idx)!
	e.run_startup_hooks(mut app, idx, lane)!
	if job == none {
		return
	}
	mut state := e.state
	state.mu.@lock()
	current := state.job_schedule or {
		state.mu.unlock()
		return
	}
	active := !state.stopping && voidptr(current) == voidptr(schedule)
		&& schedule.source_signature == state.cached_source_signature
	state.mu.unlock()
	if active {
		e.execute_runtime_hook(mut app, idx, lane, 'scheduled', job)!
	}
}
