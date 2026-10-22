module executor

import time

fn fail_waiting_http(e InProcVjsxExecutor) bool {
	e.acquire_next_lane_tracked(80, true) or { return true }
	return false
}

fn test_http_executor_waiters_timeout_cleanup_and_slot_occupancy() {
	e := InProcVjsxExecutor{ state: &VjsxExecutorState{ lanes: [VjsxExecutionLane{ id: 'one', inflight: 1 }] } }
	job := spawn fail_waiting_http(e)
	deadline := time.ticks() + 1000
	for e.http_load_snapshot().waiting == 0 && time.ticks() < deadline {
		time.sleep(time.millisecond)
	}
	busy := e.http_load_snapshot()
	assert busy.waiting == 1
	assert busy.occupied == 1
	assert busy.capacity == 1
	assert job.wait()
	idle_queue := e.http_load_snapshot()
	assert idle_queue.waiting == 0
	assert idle_queue.queue_waits_total == 1
	assert idle_queue.queue_timeouts_total == 1
	assert idle_queue.last_queue_timeout_unix > 0
	e.release_lane('one')
	assert e.http_load_snapshot().occupied == 0
	lane := e.acquire_next_lane_tracked(10, true) or { panic(err) }
	assert lane.id == 'one'
	assert e.http_load_snapshot().queue_waits_total == 1
	e.release_lane(lane.id)
}
