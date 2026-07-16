module executor

import log

struct InProcVjsxLaneWorkerRuntime {}

fn InProcVjsxLaneWorkerRuntime.loop(state &VjsxExecutorState, lane_id string, task_ch chan InProcVjsxWebSocketTask, snapshot_ch chan InProcVjsxLaneSnapshotTask, warmup_ch chan InProcVjsxLaneWarmupTask, pump_ch chan InProcVjsxLanePumpTask, affinity_ch chan InProcVjsxLaneAffinityTask, stop_ch chan bool) {
	worker_executor := InProcVjsxExecutor{
		state: unsafe { state }
	}
	for {
		select {
			_ := <-stop_ch {
				return
			}
			mut task := <-task_ch {
				mut response_json := ''
				mut err_msg := ''
				mut task_app := task.app
				defer {
					if task.actor_serialized {
						worker_executor.finish_websocket_mailbox_task(task.actor_key)
					} else if WebSocketAffinityPolicy.should_pin_lane(task.frame, task.affinity_key) {
						worker_executor.finish_websocket_mailbox_task(task.affinity_key)
					}
					worker_executor.release_lane(lane_id)
				}
				task.started <- true
				if task.frame.event == 'open' {
				}
				log.debug('[vhttpd] lane worker recv lane=${lane_id} event=${task.frame.event} request_id=${task.frame.request_id} trace_id=${task.frame.trace_id}')
				lane := worker_executor.lane_snapshot_by_id(lane_id) or {
					err_msg = InProcVjsxError.normalize_message(err.msg(),
						'inproc_vjsx_executor_lane_not_found')
					log.debug('[vhttpd] lane worker reply_error lane=${lane_id} event=${task.frame.event} request_id=${task.frame.request_id} error=${err_msg}')
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxWebSocketTaskResult{
						ok:    false
						error: err_msg
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				response_json = worker_executor.dispatch_websocket_callback_on_lane(mut task_app,
					task.frame, lane) or {
					err_msg = InProcVjsxError.normalize_message(err.msg(),
						'inproc_vjsx_executor_websocket_dispatch_failed')
					eprintln('[vhttpd] websocket lane worker error lane=${lane_id} event=${task.frame.event} path=${task.frame.path} request_id=${task.frame.request_id} trace_id=${task.frame.trace_id} query=${task.frame.query} error=${err_msg}')
					log.debug('[vhttpd] lane worker reply_error lane=${lane_id} event=${task.frame.event} request_id=${task.frame.request_id} error=${err_msg}')
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxWebSocketTaskResult{
						ok:    false
						error: err_msg
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				log.debug('[vhttpd] lane worker reply_ok lane=${lane_id} event=${task.frame.event} request_id=${task.frame.request_id} response_len=${response_json.len}')
				task.slot.mu.@lock()
				task.slot.result = InProcVjsxWebSocketTaskResult{
					ok:            true
					response_json: response_json
				}
				task.slot.ready = true
				task.slot.mu.unlock()
				task.done <- true
			}
			mut task := <-snapshot_ch {
				InProcVjsxLaneWorkerRuntime.handle_snapshot_task(worker_executor, lane_id, mut task)
			}
			mut task := <-warmup_ch {
				InProcVjsxLaneWorkerRuntime.handle_warmup_task(worker_executor, lane_id, mut task)
			}
			mut task := <-pump_ch {
				InProcVjsxLaneWorkerRuntime.handle_pump_task(worker_executor, lane_id, mut task)
			}
			mut task := <-affinity_ch {
				InProcVjsxLaneWorkerRuntime.handle_affinity_task(worker_executor, lane_id, mut task)
			}
		}
	}
}
