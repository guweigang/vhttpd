module executor

import upstream.transport

fn mailbox_limit_task(key string, data string) InProcVjsxWebSocketTask {
	return InProcVjsxWebSocketTask{
		app: NoOpAppFacade{}
		affinity_key: key
		frame: transport.WorkerWebSocketFrame{data: data}
		slot: &InProcVjsxWebSocketTaskSlot{}
		done: chan bool{cap: 1}
		started: chan bool{cap: 1}
	}
}

fn test_mailbox_key_limit_rejection_wakes_both_waiters() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	defer { exec.close() }
	for _ in 0 .. websocket_mailbox_key_limit { exec.enqueue_websocket_mailbox_task(mailbox_limit_task('key', '')) }
	mut rejected := mailbox_limit_task('key', '')
	exec.enqueue_websocket_mailbox_task(rejected)
	assert exec.state.tasks.len == websocket_mailbox_key_limit
	exec.await_websocket_start(rejected.started, mut rejected.slot) or {
		assert err.msg() == 'inproc_vjsx_executor_mailbox_capacity'
		assert rejected.slot.control.notified
		return
	}
	assert false
}

fn test_mailbox_expired_head_cannot_start_or_restore() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	defer { exec.close() }
	mut task := mailbox_limit_task('expired', '')
	exec.enqueue_websocket_mailbox_task(task)
	task.slot.control.mailbox_deadline = 1
	assert !exec.begin_task(mut task.slot.control, '')
	assert exec.state.tasks.len == 0
	assert exec.state.websocket_mailbox_by_key.len == 0
	exec.restore_websocket_mailbox_task('expired', task)
	assert exec.state.websocket_mailbox_by_key.len == 0
}

fn test_mailbox_oversize_frame_never_enters_registry() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	defer { exec.close() }
	mut task := mailbox_limit_task('key', 'x'.repeat(websocket_mailbox_frame_limit))
	exec.enqueue_websocket_mailbox_task(task)
	assert exec.state.tasks.len == 0
	assert task.slot.control.reason == 'inproc_vjsx_executor_mailbox_capacity'
}

fn test_mailbox_global_count_limit_covers_distinct_keys() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	defer { exec.close() }
	for index in 0 .. websocket_mailbox_task_limit {
		exec.enqueue_websocket_mailbox_task(mailbox_limit_task(index.str(), ''))
	}
	mut rejected := mailbox_limit_task('extra', '')
	exec.enqueue_websocket_mailbox_task(rejected)
	assert exec.state.tasks.len == websocket_mailbox_task_limit
	assert rejected.slot.control.reason == 'inproc_vjsx_executor_mailbox_capacity'
}

fn test_mailbox_total_bytes_reject_before_count_limit() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	defer { exec.close() }
	for _ in 0 .. 40 { exec.enqueue_websocket_mailbox_task(mailbox_limit_task('key', 'x'.repeat(512 * 1024))) }
	assert exec.state.tasks.len < 32
	assert exec.state.tasks.len > 0
}
