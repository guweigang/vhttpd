module executor

import upstream.transport

fn affinity_owner_select(exec InProcVjsxExecutor, id string, key string) InProcVjsxWebSocketTask {
	task := InProcVjsxWebSocketTask{
		app:          NoOpAppFacade{}
		frame:        transport.WorkerWebSocketFrame{ id: id, event: 'open' }
		affinity_key: key
		slot:         &InProcVjsxWebSocketTaskSlot{}
		done:         chan bool{cap: 1}
		started:      chan bool{cap: 1}
	}
	mut state := exec.state
	state.websocket_mailbox_by_key[key] = [task]
	state.websocket_mailbox_pending_keys = [key]
	_ := state.take_websocket_mailbox_task() or { panic('missing selection') }
	return task
}

fn test_mailbox_binding_counts_connections_once_and_close_releases_last_owner() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	one := affinity_owner_select(exec, 'one', 'shared')
	exec.bind_websocket_task_lane(one, 'lane')
	exec.bind_websocket_task_lane(one, 'lane')
	assert exec.state.websocket_affinity_ref_count_by_key['shared'] == 1
	exec.state.websocket_mailbox_running_by_key.delete('shared')
	two := affinity_owner_select(exec, 'two', 'shared')
	exec.bind_websocket_task_lane(two, 'lane')
	assert exec.state.websocket_affinity_ref_count_by_key['shared'] == 2
	exec.release_websocket_connection_affinity(transport.WorkerWebSocketFrame{ id: 'one' })
	assert exec.state.websocket_affinity_ref_count_by_key['shared'] == 1
	exec.release_websocket_connection_affinity(transport.WorkerWebSocketFrame{ id: 'two' })
	assert 'shared' !in exec.state.websocket_affinity_ref_count_by_key
	assert 'shared' !in exec.state.websocket_mailbox_running_by_key
	assert exec.state.websocket_connection_affinity_key_by_id.len == 0
}

fn test_last_bound_connection_close_cancels_queued_mailbox_without_manual_refcount() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	bound := affinity_owner_select(exec, 'one', 'shared')
	exec.bind_websocket_task_lane(bound, 'lane')
	exec.state.websocket_mailbox_running_by_key.delete('shared')
	mut pending := InProcVjsxWebSocketTask{
		app:          NoOpAppFacade{}
		affinity_key: 'shared'
		slot:         &InProcVjsxWebSocketTaskSlot{}
		done:         chan bool{cap: 1}
		started:      chan bool{cap: 1}
	}
	exec.enqueue_websocket_mailbox_task(pending)
	exec.release_websocket_connection_affinity(transport.WorkerWebSocketFrame{ id: 'one' })
	assert pending.slot.control.reason == 'inproc_vjsx_executor_websocket_affinity_released'
	assert exec.state.websocket_mailbox_by_key.len == 0
	assert exec.state.tasks.len == 0
}

fn test_migration_keeps_existing_target_lane_and_transfers_only_one_reference() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	exec.state.websocket_connection_affinity_key_by_id = {
		'one': 'source'
		'two': 'target'
	}
	exec.state.websocket_connection_lane_by_id = {
		'one': 'source-lane'
		'two': 'target-lane'
	}
	exec.state.websocket_affinity_lane_by_key = {
		'source': 'source-lane'
		'target': 'target-lane'
	}
	exec.state.websocket_affinity_ref_count_by_key = {
		'source': 1
		'target': 1
	}
	exec.migrate_websocket_connection_affinity(transport.WorkerWebSocketFrame{ id: 'one' }, 'target', 'source-lane')
	assert exec.state.websocket_connection_lane_by_id['one'] == 'target-lane'
	assert exec.state.websocket_affinity_lane_by_key['target'] == 'target-lane'
	assert exec.state.websocket_affinity_ref_count_by_key['target'] == 2
	assert 'source' !in exec.state.websocket_affinity_ref_count_by_key
}

fn test_late_mailbox_binding_cannot_rebind_a_migrated_connection() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	old := affinity_owner_select(exec, 'one', 'source')
	exec.bind_websocket_task_lane(old, 'source-lane')
	exec.migrate_websocket_connection_affinity(transport.WorkerWebSocketFrame{ id: 'one' }, 'target', 'source-lane')
	exec.bind_websocket_task_lane(old, 'wrong-lane')
	assert exec.state.websocket_connection_affinity_key_by_id['one'] == 'target'
	assert exec.state.websocket_connection_lane_by_id['one'] == 'source-lane'
	assert exec.state.websocket_affinity_ref_count_by_key['target'] == 1
}

fn test_migration_to_fresh_key_preserves_source_lane_and_repeated_commit_is_idempotent() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	one := affinity_owner_select(exec, 'one', 'source')
	exec.bind_websocket_task_lane(one, 'source-lane')
	frame := transport.WorkerWebSocketFrame{ id: 'one' }
	exec.migrate_websocket_connection_affinity(frame, 'fresh', 'unused-lane')
	exec.migrate_websocket_connection_affinity(frame, 'fresh', 'another-lane')
	assert exec.state.websocket_connection_lane_by_id['one'] == 'source-lane'
	assert exec.state.websocket_affinity_ref_count_by_key['fresh'] == 1
	assert 'source' !in exec.state.websocket_affinity_ref_count_by_key
	exec.release_websocket_connection_affinity(frame)
	exec.release_websocket_connection_affinity(frame)
	assert exec.state.websocket_affinity_ref_count_by_key.len == 0
}

fn test_retired_mailbox_binding_cannot_add_an_affinity_reference() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	old := affinity_owner_select(exec, 'old', 'shared')
	exec.state.websocket_mailbox_running_by_key.delete('shared')
	next := affinity_owner_select(exec, 'next', 'shared')
	exec.bind_websocket_task_lane(next, 'current-lane')
	exec.bind_websocket_task_lane(old, 'old-lane')
	assert exec.state.websocket_affinity_ref_count_by_key['shared'] == 1
	assert 'old' !in exec.state.websocket_connection_affinity_key_by_id
	assert exec.state.websocket_affinity_lane_by_key['shared'] == 'current-lane'
}

fn test_rejected_open_releases_affinity_without_publishing_response_migration() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	one := affinity_owner_select(exec, 'one', 'source')
	exec.bind_websocket_task_lane(one, 'lane')
	response := exec.finalize_websocket_dispatch_response(one.frame, 'source', 'lane', 'actor', 'class', true,
		InProcVjsxWebSocketTaskResult{ ok: true, response_json: '{"accepted":false,"affinity_key":"rejected-target"}' })
	assert !response.accepted
	assert exec.state.websocket_connection_affinity_key_by_id.len == 0
	assert exec.state.websocket_affinity_ref_count_by_key.len == 0
	assert exec.state.websocket_connection_actor_key_by_id.len == 0
	assert 'rejected-target' !in exec.state.websocket_affinity_lane_by_key
}

fn test_close_response_cannot_create_a_persistent_affinity_binding() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	one := affinity_owner_select(exec, 'one', 'source')
	exec.bind_websocket_task_lane(one, 'lane')
	frame := transport.WorkerWebSocketFrame{ id: 'one', event: 'close' }
	exec.finalize_websocket_dispatch_response(frame, 'source', 'lane', '', '', false,
		InProcVjsxWebSocketTaskResult{ ok: true, response_json: '{"affinity_key":"closed-target"}' })
	assert 'closed-target' !in exec.state.websocket_affinity_lane_by_key
	assert exec.state.websocket_affinity_ref_count_by_key.len == 0
	assert exec.state.websocket_connection_affinity_key_by_id.len == 0
}

fn test_rejected_actor_open_does_not_cache_a_connection_decision() {
	mut exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	frame := transport.WorkerWebSocketFrame{ id: 'one', event: 'open' }
	exec.finalize_websocket_dispatch_response(frame, '', '', 'actor', 'class', true,
		InProcVjsxWebSocketTaskResult{ ok: true, response_json: '{"accepted":false}' })
	assert exec.state.websocket_connection_actor_key_by_id.len == 0
	assert exec.state.websocket_connection_actor_class_by_id.len == 0
}
