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
				mut task_app := task.app
				lane := worker_executor.lane_snapshot_by_id(lane_id) or {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneSnapshotTaskResult{
						ok:    false
						error: InProcVjsxError.normalize_message(err.msg(),
							'inproc_vjsx_executor_lane_not_found')
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				idx := worker_executor.lane_index_by_id(lane.id)
				if idx < 0 {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneSnapshotTaskResult{
						ok:    false
						error: 'inproc_vjsx_executor_lane_not_found'
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				raw := worker_executor.execute_snapshot_hook(mut task_app, idx, lane) or {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneSnapshotTaskResult{
						ok:    false
						error: InProcVjsxError.normalize_message(err.msg(),
							'inproc_vjsx_executor_snapshot_failed')
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				task.slot.mu.@lock()
				task.slot.result = InProcVjsxLaneSnapshotTaskResult{
					ok:  true
					raw: raw
				}
				task.slot.ready = true
				task.slot.mu.unlock()
				task.done <- true
			}
			mut task := <-warmup_ch {
				mut task_app := task.app
				lane := worker_executor.lane_snapshot_by_id(lane_id) or {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneWarmupTaskResult{
						ok:    false
						error: InProcVjsxError.normalize_message(err.msg(),
							'inproc_vjsx_executor_lane_not_found')
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				idx := worker_executor.lane_index_by_id(lane.id)
				log.debug('[vhttpd] lane warmup begin lane=${lane.id} idx=${idx}')
				if idx < 0 {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneWarmupTaskResult{
						ok:    false
						error: 'inproc_vjsx_executor_lane_not_found'
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				worker_executor.ensure_lane_host(idx) or {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneWarmupTaskResult{
						ok:    false
						error: InProcVjsxError.normalize_message(err.msg(),
							'inproc_vjsx_executor_warmup_host_failed')
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				worker_executor.run_startup_hooks(mut task_app, idx, lane) or {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneWarmupTaskResult{
						ok:    false
						error: InProcVjsxError.normalize_message(err.msg(),
							'inproc_vjsx_executor_warmup_startup_failed')
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				log.debug('[vhttpd] lane warmup done lane=${lane.id} idx=${idx}')
				task.slot.mu.@lock()
				task.slot.result = InProcVjsxLaneWarmupTaskResult{
					ok: true
				}
				task.slot.ready = true
				task.slot.mu.unlock()
				task.done <- true
			}
			mut task := <-pump_ch {
				idx := worker_executor.lane_index_by_id(lane_id)
				if idx < 0 {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLanePumpTaskResult{
						ok:    false
						error: 'inproc_vjsx_executor_lane_not_found'
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				mut state_pump := worker_executor.state
				state_pump.mu.@lock()
				host := state_pump.hosts[idx]
				state_pump.mu.unlock()
				host.pump_until_idle()
				task.slot.mu.@lock()
				task.slot.result = InProcVjsxLanePumpTaskResult{
					ok: true
				}
				task.slot.ready = true
				task.slot.mu.unlock()
				task.done <- true
			}
			mut task := <-affinity_ch {
				mut task_app := task.app
				defer {
					worker_executor.release_lane(lane_id)
				}
				lane := worker_executor.lane_snapshot_by_id(lane_id) or {
					task.slot.mu.@lock()
					task.slot.result = InProcVjsxLaneAffinityTaskResult{
						ok:    false
						error: InProcVjsxError.normalize_message(err.msg(),
							'inproc_vjsx_executor_lane_not_found')
					}
					task.slot.ready = true
					task.slot.mu.unlock()
					task.done <- true
					continue
				}
				mut affinity_decision := WebSocketAffinityDecision{}
				mut actor_decision := WebSocketActorDecision{}
				if task.kind == 'actor' {
					actor_decision = worker_executor.resolve_websocket_actor_on_lane(mut task_app,
						task.frame, lane) or {
						task.slot.mu.@lock()
						task.slot.result = InProcVjsxLaneAffinityTaskResult{
							ok:    false
							error: InProcVjsxError.normalize_message(err.msg(),
								'inproc_vjsx_executor_websocket_actor_failed')
						}
						task.slot.ready = true
						task.slot.mu.unlock()
						task.done <- true
						continue
					}
				} else {
					affinity_decision = worker_executor.resolve_websocket_affinity_on_lane(mut task_app,
						task.frame, lane) or {
						task.slot.mu.@lock()
						task.slot.result = InProcVjsxLaneAffinityTaskResult{
							ok:    false
							error: InProcVjsxError.normalize_message(err.msg(),
								'inproc_vjsx_executor_websocket_affinity_failed')
						}
						task.slot.ready = true
						task.slot.mu.unlock()
						task.done <- true
						continue
					}
				}
				task.slot.mu.@lock()
				task.slot.result = InProcVjsxLaneAffinityTaskResult{
					ok:    true
					value: affinity_decision
					actor: actor_decision
				}
				task.slot.ready = true
				task.slot.mu.unlock()
				task.done <- true
			}
		}
	}
}
