module executor

import log
import time

struct InProcVjsxLaneWorkerRuntime {}

fn InProcVjsxLaneWorkerRuntime.loop(state &VjsxExecutorState, lane_id string, task_ch chan InProcVjsxWebSocketTask, snapshot_ch chan InProcVjsxLaneSnapshotTask, warmup_ch chan InProcVjsxLaneWarmupTask, pump_ch chan InProcVjsxLanePumpTask, affinity_ch chan InProcVjsxLaneAffinityTask, stop_ch chan bool) {
	worker_executor := InProcVjsxExecutor{
		state: unsafe { state }
	}
	mut draining := false
	for {
		// A stop notification switches the same loop to a nonblocking drain.
		// Idle workers block normally; no per-lane polling is needed.
		idle_timeout := if draining { time.Duration(0) } else { time.Duration(9223372036854775807) }
		// V3 treats select bindings as immutable; copy each received task to a mutable local.
		select {
			_ := <-stop_ch {
				draining = true
			}
			received := <-task_ch {
				mut task := received
				if !worker_executor.begin_task(mut task.slot.control, lane_id) { continue }
				defer { worker_executor.finish_task(mut task.slot.control) }
				mut response_json := ''
				mut err_msg := ''
				mut task_app := task.app

				select {
					task.started <- true {
					}
					else {
					}
				}
				if task.frame.event == 'open' {
				}
				log.debug('[vhttpd] lane worker recv lane=${lane_id} event=${task.frame.event} request_id=${task.frame.request_id} trace_id=${task.frame.trace_id}')
				lane := worker_executor.lane_snapshot_by_id(lane_id) or {
					err_msg = 'inproc_vjsx_executor_lane_not_found'
					log.debug('[vhttpd] lane worker reply_error lane=${lane_id} event=${task.frame.event} request_id=${task.frame.request_id} error=${err_msg}')
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxWebSocketTaskResult{
						ok:    false
						error: err_msg
					}
					task.slot.ready = true
					task.slot.mu.unlock()
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
			}
			received := <-snapshot_ch {
				mut task := received
				if !worker_executor.begin_task(mut task.slot.control, lane_id) {
					if task_is_pending(task.slot.control) {
						worker := worker_executor.lane_worker_by_id(lane_id) or {
							worker_executor.cancel_task(mut task.slot.control, 'inproc_vjsx_executor_lane_worker_missing')
							continue
						}
						worker_executor.submit_snapshot_task(worker, task) or {
							worker_executor.cancel_task(mut task.slot.control, err.msg())
						}
						time.sleep(5 * time.millisecond)
					}
					continue
				}
				defer { worker_executor.finish_task(mut task.slot.control) }
				InProcVjsxLaneWorkerRuntime.handle_snapshot_task(worker_executor, lane_id, mut task)
			}
			received := <-warmup_ch {
				mut task := received
				if !worker_executor.begin_task(mut task.slot.control, lane_id) {
					if task_is_pending(task.slot.control) {
						worker := worker_executor.lane_worker_by_id(lane_id) or {
							worker_executor.cancel_task(mut task.slot.control, 'inproc_vjsx_executor_lane_worker_missing')
							continue
						}
						worker_executor.submit_warmup_task(worker, task) or {
							worker_executor.cancel_task(mut task.slot.control, err.msg())
						}
						time.sleep(5 * time.millisecond)
					}
					continue
				}
				defer { worker_executor.finish_task(mut task.slot.control) }
				InProcVjsxLaneWorkerRuntime.handle_warmup_task(worker_executor, lane_id, mut task)
			}
			received := <-pump_ch {
				mut task := received
				if !worker_executor.begin_task(mut task.slot.control, lane_id) {
					if task_is_pending(task.slot.control) {
						worker := worker_executor.lane_worker_by_id(lane_id) or {
							worker_executor.cancel_task(mut task.slot.control, 'inproc_vjsx_executor_lane_worker_missing')
							continue
						}
						worker_executor.submit_pump_task(worker, task) or {
							worker_executor.cancel_task(mut task.slot.control, err.msg())
						}
						time.sleep(5 * time.millisecond)
					}
					continue
				}
				defer { worker_executor.finish_task(mut task.slot.control) }
				InProcVjsxLaneWorkerRuntime.handle_pump_task(worker_executor, lane_id, mut task)
			}
			received := <-affinity_ch {
				mut task := received
				if !worker_executor.begin_task(mut task.slot.control, lane_id) { continue }
				defer { worker_executor.finish_task(mut task.slot.control) }
				InProcVjsxLaneWorkerRuntime.handle_affinity_task(worker_executor, lane_id, mut task)
			}
			idle_timeout {
				if draining { return }
			}
		}
	}
}
