module executor

fn mailbox_claim_task(key string) InProcVjsxWebSocketTask {
	return InProcVjsxWebSocketTask{
		app:          NoOpAppFacade{}
		affinity_key: key
		slot:         &InProcVjsxWebSocketTaskSlot{ control: &ExecutorTaskControl{ mailbox_key: key } }
		done:         chan bool{cap: 1}
		started:      chan bool{cap: 1}
	}
}

fn mailbox_claim_select(exec InProcVjsxExecutor, task InProcVjsxWebSocketTask) {
	mut state := exec.state
	state.websocket_mailbox_by_key['shared'] = [task]
	state.websocket_mailbox_pending_keys = ['shared']
	selected := state.take_websocket_mailbox_task() or { panic('missing selection') }
	assert voidptr(selected.task.slot) == voidptr(task.slot)
}

fn test_old_mailbox_completion_cannot_release_recreated_key_claim() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	mut old := mailbox_claim_task('shared')
	old.slot.control.phase = .running
	old.slot.control.lane_id = 'old-lane'
	exec.state.tasks[task_control_id(old.slot.control)] = old.slot.control
	mailbox_claim_select(exec, old)
	exec.state.websocket_affinity_ref_count_by_key['shared'] = 1
	exec.release_websocket_affinity_key('shared')
	next := mailbox_claim_task('shared')
	mailbox_claim_select(exec, next)
	exec.finish_task(mut old.slot.control)
	assert 'shared' in exec.state.websocket_mailbox_running_by_key
}

fn test_cancelled_old_restore_cannot_release_recreated_key_claim() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	old := mailbox_claim_task('shared')
	exec.state.tasks[task_control_id(old.slot.control)] = old.slot.control
	mailbox_claim_select(exec, old)
	exec.state.websocket_affinity_ref_count_by_key['shared'] = 1
	exec.release_websocket_affinity_key('shared')
	assert old.slot.control.reason != ''
	next := mailbox_claim_task('shared')
	mailbox_claim_select(exec, next)
	exec.restore_websocket_mailbox_task('shared', old)
	assert 'shared' in exec.state.websocket_mailbox_running_by_key
	assert exec.state.websocket_mailbox_by_key.len == 0
}

fn test_pending_cancel_after_withdrawal_cannot_release_replacement_claim() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	mut old := mailbox_claim_task('shared')
	old.slot.control.owns_lane = true
	old.slot.control.lane_id = 'old-lane'
	mailbox_claim_select(exec, old)
	// Model the gap after affinity withdrawal unlocks and before it cancels
	// captured pending controls: a new task can already own the same key.
	exec.state.websocket_mailbox_running_by_key.delete('shared')
	next := mailbox_claim_task('shared')
	mailbox_claim_select(exec, next)
	assert exec.cancel_task(mut old.slot.control, 'retired')
	assert 'shared' in exec.state.websocket_mailbox_running_by_key
}

fn test_cancel_selected_task_before_lane_transfer_releases_its_claim() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	mut task := mailbox_claim_task('shared')
	mailbox_claim_select(exec, task)
	assert !task.slot.control.owns_lane
	assert exec.cancel_task(mut task.slot.control, 'expired')
	assert 'shared' !in exec.state.websocket_mailbox_running_by_key
}

fn test_retired_mailbox_selection_cannot_rebind_replacement_lane() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	old := mailbox_claim_task('shared')
	exec.state.tasks[task_control_id(old.slot.control)] = old.slot.control
	mailbox_claim_select(exec, old)
	exec.state.websocket_affinity_ref_count_by_key['shared'] = 1
	exec.release_websocket_affinity_key('shared')
	next := mailbox_claim_task('shared')
	mailbox_claim_select(exec, next)
	exec.bind_websocket_task_lane(next, 'new-lane')
	exec.bind_websocket_task_lane(old, 'old-lane')
	assert exec.state.websocket_affinity_lane_by_key['shared'] == 'new-lane'
}

fn test_unregistered_old_selection_cannot_restore_into_recreated_mailbox() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	old := mailbox_claim_task('shared')
	mailbox_claim_select(exec, old)
	exec.state.websocket_affinity_ref_count_by_key['shared'] = 1
	exec.release_websocket_affinity_key('shared')
	// A failed worker enqueue can temporarily remove the task registry entry.
	// Claim withdrawal still retires this selection even without cancellation.
	assert old.slot.control.reason == ''
	next := mailbox_claim_task('shared')
	mailbox_claim_select(exec, next)
	exec.restore_websocket_mailbox_task('shared', old)
	assert exec.state.websocket_mailbox_running_by_key['shared'] == task_control_id(next.slot.control)
	assert exec.state.websocket_mailbox_by_key.len == 0
	assert old.slot.control.reason == 'inproc_vjsx_executor_mailbox_retired'
	assert old.slot.control.phase == .cancelled
}

fn test_retired_mailbox_selection_cannot_enter_worker_queue() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	old := mailbox_claim_task('shared')
	mailbox_claim_select(exec, old)
	exec.state.websocket_mailbox_running_by_key.delete('shared')
	mut next := mailbox_claim_task('shared')
	mailbox_claim_select(exec, next)
	worker := VjsxLaneWorker{ lane_id: 'lane', websocket_tasks: chan InProcVjsxWebSocketTask{cap: 1} }
	if _ := exec.submit_websocket_task(worker, old) {
		assert false, 'retired mailbox selection entered the worker queue'
	} else {
		assert err.msg() == 'inproc_vjsx_executor_mailbox_retired'
	}
	assert exec.state.tasks.len == 0
	exec.submit_websocket_task(worker, next) or { panic(err) }
	queued := <-worker.websocket_tasks
	assert voidptr(queued.slot) == voidptr(next.slot)
	assert exec.cancel_task(mut next.slot.control, 'test complete')
}

fn test_queued_retired_mailbox_task_cannot_begin_execution() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	exec.state.lanes = [VjsxExecutionLane{ id: 'lane', inflight: 1 }]
	mut old := mailbox_claim_task('shared')
	mailbox_claim_select(exec, old)
	worker := VjsxLaneWorker{ lane_id: 'lane', websocket_tasks: chan InProcVjsxWebSocketTask{cap: 1} }
	exec.submit_websocket_task(worker, old) or { panic(err) }
	_ := <-worker.websocket_tasks
	// Withdrawal can precede its deferred cancellation after the task is queued.
	exec.state.websocket_mailbox_running_by_key.delete('shared')
	next := mailbox_claim_task('shared')
	mailbox_claim_select(exec, next)
	assert !exec.begin_task(mut old.slot.control, 'lane')
	assert old.slot.control.reason == 'inproc_vjsx_executor_mailbox_retired'
	assert exec.state.lanes[0].inflight == 0
	assert exec.state.active_task_by_lane.len == 0
	assert exec.state.websocket_mailbox_running_by_key['shared'] == task_control_id(next.slot.control)
}
