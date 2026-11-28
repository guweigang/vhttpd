module executor

import os
import time
import upstream.transport

fn mailbox_memory_soak_batch() {
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	for index in 0 .. 128 {
		task := InProcVjsxWebSocketTask{
			app:          NoOpAppFacade{}
			affinity_key: 'key-${index % 4}'
			frame:        transport.WorkerWebSocketFrame{ data: 'x'.repeat(4096) }
			slot:         &InProcVjsxWebSocketTaskSlot{}
			done:         chan bool{cap: 1}
			started:      chan bool{cap: 1}
		}
		exec.enqueue_websocket_mailbox_task(task)
	}
	exec.close()
	assert exec.state.tasks.len == 0
	assert exec.state.websocket_mailbox_by_key.len == 0
}

fn test_mailbox_long_memory_soak() {
	seconds := os.getenv('VHTTPD_MAILBOX_SOAK_SECONDS').int()
	if seconds <= 0 { return }
	assert gc_is_enabled()
	assert seconds >= 180
	clock := time.new_stopwatch()
	mut baseline := u64(0)
	mut rounds := 0
	for clock.elapsed().seconds() < seconds {
		if clock.elapsed().seconds() < seconds - 60 {
			mailbox_memory_soak_batch()
			rounds++
		} else {
			gc_collect()
			time.sleep(time.second)
		}
		if clock.elapsed().seconds() >= 30 && baseline == 0 {
			gc_collect()
			baseline = u64(gc_memory_use())
		}
	}
	gc_collect()
	settled := u64(gc_memory_use())
	println('MAILBOX_SOAK_RESULT baseline=${baseline} settled=${settled} rounds=${rounds}')
	assert settled <= baseline + 32 * 1024 * 1024
}
