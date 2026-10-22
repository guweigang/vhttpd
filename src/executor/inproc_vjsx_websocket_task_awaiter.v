module executor

fn (e InProcVjsxExecutor) await_websocket_result(done_ch chan bool, mut slot InProcVjsxWebSocketTaskSlot) !InProcVjsxWebSocketTaskResult {
	e.await_task(done_ch, mut slot.control, inproc_vjsx_lane_task_timeout, 'inproc_vjsx_executor_lane_task_timeout')!
	slot.mu.@lock()
	result := slot.result
	ready := slot.ready
	slot.mu.unlock()
	if !ready {
		return error('inproc_vjsx_executor_lane_task_not_ready')
	}
	if !result.ok {
		return error(result.error)
	}
	return result
}

fn (e InProcVjsxExecutor) await_websocket_start(started chan bool, mut slot InProcVjsxWebSocketTaskSlot) ! {
	select {
		_ := <-started {
		}
		inproc_vjsx_websocket_queue_wait_timeout {
			e.cancel_task(mut slot.control, 'inproc_vjsx_executor_websocket_queue_timeout')
		}
	}
	slot.control.mu.@lock()
	reason := slot.control.reason
	slot.control.mu.unlock()
	if reason != '' { return error(reason) }
}
