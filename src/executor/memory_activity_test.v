module executor

import memidle

fn test_lane_reservations_and_release_share_global_memory_activity() {
	e := InProcVjsxExecutor{state: &VjsxExecutorState{lanes:[VjsxExecutionLane{id:'idle-test',healthy:true}]}}
	base := memidle.stats().active
	lane := e.acquire_next_lane(1) or { panic(err) }
	assert memidle.stats().active == base+1
	e.release_lane(lane.id)
	assert memidle.stats().active == base
	// A duplicate release must not decrement activity belonging to another scope.
	memidle.begin()
	e.release_lane(lane.id)
	assert memidle.stats().active == base+1
	memidle.end()
}
