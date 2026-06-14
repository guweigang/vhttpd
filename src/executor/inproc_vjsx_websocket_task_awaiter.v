module executor

struct InProcVjsxWebSocketTaskAwaiter {}

fn InProcVjsxWebSocketTaskAwaiter.result(done_ch chan bool, mut slot InProcVjsxWebSocketTaskSlot) !InProcVjsxWebSocketTaskResult {
	select {
		_ := <-done_ch {}
		inproc_vjsx_lane_task_timeout {
			return error('inproc_vjsx_executor_lane_task_timeout')
		}
	}
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

fn InProcVjsxWebSocketTaskAwaiter.start(started_ch chan bool) ! {
	select {
		_ := <-started_ch {}
		inproc_vjsx_websocket_queue_wait_timeout {
			return error('inproc_vjsx_executor_websocket_queue_timeout')
		}
	}
}
