module executor

import upstream.transport

fn mailbox_test_task(id string, priority int, actor bool) InProcVjsxWebSocketTask {
	return InProcVjsxWebSocketTask{
		app:               NoOpAppFacade{}
		frame:             transport.WorkerWebSocketFrame{ id: id }
		slot:              &InProcVjsxWebSocketTaskSlot{}
		done:              chan bool{cap: 1}
		started:           chan bool{cap: 1}
		affinity_priority: priority
		actor_priority:    priority
		actor_serialized:  actor
	}
}

fn test_mailbox_empty_and_stale_keys_return_no_task() {
	mut state := VjsxExecutorState{}
	if _ := state.take_websocket_mailbox_task() { panic('unexpected mailbox task') }
	state.websocket_mailbox_pending_keys = ['stale', 'empty', 'stale']
	state.websocket_mailbox_by_key['empty'] = []InProcVjsxWebSocketTask{}
	if _ := state.take_websocket_mailbox_task() { panic('unexpected mailbox task') }
	assert state.websocket_mailbox_pending_keys.len == 0
	assert state.websocket_mailbox_running_by_key.len == 0
}

fn test_mailbox_priority_fifo_and_running_exclusion_preserve_slots() {
	mut state := VjsxExecutorState{}
	first := mailbox_test_task('first', 2, false)
	second := mailbox_test_task('second', 99, false)
	actor := mailbox_test_task('actor', 8, true)
	state.websocket_mailbox_pending_keys = ['affinity', 'actor', 'affinity']
	state.websocket_mailbox_by_key['affinity'] = [first, second]
	state.websocket_mailbox_by_key['actor'] = [actor]
	chosen := state.take_websocket_mailbox_task() or { panic('missing actor') }
	assert chosen.key == 'actor'
	assert voidptr(chosen.task.slot) == voidptr(actor.slot)
	assert 'actor' in state.websocket_mailbox_running_by_key
	assert 'actor' !in state.websocket_mailbox_by_key
	chosen_affinity := state.take_websocket_mailbox_task() or { panic('missing affinity') }
	assert chosen_affinity.task.frame.id == 'first'
	assert voidptr(chosen_affinity.task.slot) == voidptr(first.slot)
	remaining := state.websocket_mailbox_by_key['affinity'] or { panic('lost affinity queue') }
	assert voidptr(remaining[0].slot) == voidptr(second.slot)
	if _ := state.take_websocket_mailbox_task() { panic('unexpected mailbox task') }
	assert state.websocket_mailbox_pending_keys == ['affinity']
	state.websocket_mailbox_running_by_key.delete('affinity')
	last := state.take_websocket_mailbox_task() or { panic('missing second') }
	assert voidptr(last.task.slot) == voidptr(second.slot)
	assert state.websocket_mailbox_pending_keys.len == 0
}

fn test_task_copies_share_completion_slot_and_buffered_signal() {
	mut original := mailbox_test_task('copy', 0, false)
	mut received := original
	received.slot.mu.@lock()
	received.slot.result = InProcVjsxWebSocketTaskResult{ ok: true, response_json: 'completed' }
	received.slot.ready = true
	received.slot.mu.unlock()
	// Completion can arrive before the caller starts waiting.
	received.done <- true
	original.slot.control.phase = .completed
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	result := exec.await_websocket_result(original.done, mut original.slot) or { panic(err) }
	assert result.response_json == 'completed'
	assert voidptr(original.slot) == voidptr(received.slot)
}

fn test_constructed_executor_with_no_lanes_has_valid_shared_state() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	assert exec.lane_count() == 0
	assert exec.lane_snapshot().len == 0
	copy := exec
	assert voidptr(copy.state) == voidptr(exec.state)
	mut failed := false
	_ := exec.select_next_lane() or {
		failed = true
		assert err.msg() == 'inproc_vjsx_executor_no_lanes'
		VjsxExecutionLane{}
	}
	assert failed
	exec.close()
	exec.close()
}

fn test_mailbox_failed_lane_or_worker_lookup_restores_original_task_ownership() {
	for with_lane in [false, true] {
		mut state := &VjsxExecutorState{}
		if with_lane {
			state.lanes = [VjsxExecutionLane{ id: 'lane', healthy: true }]
		}
		exec := InProcVjsxExecutor{ state: state }
		first := mailbox_test_task('first', 1, false)
		second := mailbox_test_task('second', 1, false)
		state.websocket_mailbox_by_key['queue'] = [first, second]
		state.websocket_mailbox_pending_keys = ['queue']
		exec.try_schedule_websocket_mailboxes()
		restored := state.websocket_mailbox_by_key['queue'] or { panic('lost queue') }
		assert restored.len == 2
		assert voidptr(restored[0].slot) == voidptr(first.slot)
		assert voidptr(restored[1].slot) == voidptr(second.slot)
		assert state.websocket_mailbox_pending_keys == ['queue']
		assert 'queue' !in state.websocket_mailbox_running_by_key
		if with_lane {
			assert state.lanes[0].inflight == 0
		}
	}
}
