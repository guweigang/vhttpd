module main

import net.http
import os

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_cancel_in_other_thread_does_not_touch_active_run() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_cancel_isolated.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		first_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_cancel_active'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_cancel_active'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_cancel_active'
			target:      'chat_codexbot_ts_thread_cancel'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_thread_payload('active thread task', 'chat_codexbot_ts_thread_cancel',
				'om_codexbot_thread_cancel_active', 'om_thread_cancel_root_A', 'om_thread_cancel_parent_A')
		}) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'

		cancel_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_cancel_other'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_cancel_other'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_cancel_other'
			target:      'chat_codexbot_ts_thread_cancel'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_thread_payload('/cancel', 'chat_codexbot_ts_thread_cancel',
				'om_codexbot_thread_cancel_other', 'om_thread_cancel_root_B', 'om_thread_cancel_parent_B')
		}) or { panic(err) }
		assert cancel_resp.handled
		assert cancel_resp.commands.len == 1
		assert cancel_resp.commands[0].type_ == 'provider.message.send'
		assert cancel_resp.commands[0].target_type == 'message_id'
		assert cancel_resp.commands[0].target == 'om_codexbot_thread_cancel_other'
		assert cancel_resp.commands[0].text.contains('No active Codex run to cancel in this thread.')

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_thread_cancel_state'
			request_id:  'req_codexbot_ts_thread_cancel_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"sessionKey":"chat_codexbot_ts_thread_cancel::thread:om_thread_cancel_root_A"')
		assert state_resp.response.body.contains('"status":"queued"')
		assert !state_resp.response.body.contains('"lastEvent":"user.cancel"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_cancel_detaches_active_stream() {
	codexbot_ts_with_temp_db('codexbot_ts_cancel.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_cancel_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_cancel_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_cancel_task'
			target:      'chat_codexbot_ts_cancel'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('cancel this run', 'chat_codexbot_ts_cancel',
				'om_codexbot_cancel_task')
		}) or { panic(err) }
		stream_id := codexbot_ts_first_stream_id(task_resp.commands)
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_cancel_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_cancel_001"},"has_error":false}'
		}) or { panic(err) }

		cancel_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_cancel_cmd'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_cancel_cmd'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_cancel_cmd'
			target:      'chat_codexbot_ts_cancel'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/cancel', 'chat_codexbot_ts_cancel',
				'om_codexbot_cancel_cmd')
		}) or { panic(err) }
		assert cancel_resp.handled
		assert cancel_resp.commands.len == 3
		assert cancel_resp.commands[0].type_ == 'provider.message.update'
		assert cancel_resp.commands[0].stream_id == stream_id
		assert cancel_resp.commands[0].content.contains('Detached the active run from this chat session.')
		assert cancel_resp.commands[1].type_ == 'session.clear'
		assert cancel_resp.commands[1].provider == 'feishu'
		assert cancel_resp.commands[1].stream_id == stream_id
		assert cancel_resp.commands[2].type_ == 'session.clear'
		assert cancel_resp.commands[2].provider == 'codex'
		assert cancel_resp.commands[2].stream_id == stream_id
		assert cancel_resp.commands[2].target == 'thread_cancel_001'
		assert cancel_resp.commands[2].target_type == 'thread_id'

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_cancel_state'
			request_id:  'req_codexbot_ts_cancel_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"status":"cancelled"')
		assert state_resp.response.body.contains('"lastEvent":"user.cancel"')
		assert state_resp.response.body.contains('"threadId":""')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_cancel_interrupts_active_turn_when_turn_id_exists() {
	codexbot_ts_with_temp_db('codexbot_ts_cancel_interrupt.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_cancel_interrupt_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_cancel_interrupt_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_cancel_interrupt_task'
			target:      'chat_codexbot_ts_cancel_interrupt'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('cancel this turn', 'chat_codexbot_ts_cancel_interrupt',
				'om_codexbot_cancel_interrupt_task')
		}) or { panic(err) }
		stream_id := codexbot_ts_first_stream_id(task_resp.commands)
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_cancel_interrupt_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_cancel_interrupt_001"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_cancel_interrupt_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/started","params":{"threadId":"thread_cancel_interrupt_001","turn":{"id":"turn_cancel_interrupt_001","items":[],"status":"in_progress","error":null}}}'
		}) or { panic(err) }

		cancel_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_cancel_interrupt_cmd'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_cancel_interrupt_cmd'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_cancel_interrupt_cmd'
			target:      'chat_codexbot_ts_cancel_interrupt'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/cancel', 'chat_codexbot_ts_cancel_interrupt',
				'om_codexbot_cancel_interrupt_cmd')
		}) or { panic(err) }
		assert cancel_resp.handled
		assert cancel_resp.commands.len == 4
		assert cancel_resp.commands[0].type_ == 'provider.message.update'
		assert cancel_resp.commands[0].stream_id == stream_id
		assert cancel_resp.commands[0].content.contains('**Cancelling**')
		assert cancel_resp.commands[0].content.contains('Turn: `turn_cancel_interrupt_001`')
		assert cancel_resp.commands[1].type_ == 'provider.rpc.call'
		assert cancel_resp.commands[1].provider == 'codex'
		assert cancel_resp.commands[1].method == 'turn/interrupt'
		assert cancel_resp.commands[1].stream_id == stream_id
		assert cancel_resp.commands[1].params.contains('"threadId":"thread_cancel_interrupt_001"')
		assert cancel_resp.commands[1].params.contains('"turnId":"turn_cancel_interrupt_001"')
		assert cancel_resp.commands[2].type_ == 'session.clear'
		assert cancel_resp.commands[2].provider == 'feishu'
		assert cancel_resp.commands[3].type_ == 'session.clear'
		assert cancel_resp.commands[3].provider == 'codex'
		assert cancel_resp.commands[3].target == 'thread_cancel_interrupt_001'
		assert cancel_resp.commands[3].target_type == 'thread_id'

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_cancel_interrupt_state'
			request_id:  'req_codexbot_ts_cancel_interrupt_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"status":"cancelled"')
		assert state_resp.response.body.contains('"turnId":"turn_cancel_interrupt_001"')
		assert state_resp.response.body.contains('"lastEvent":"user.cancel.interrupt"')
		assert state_resp.response.body.contains('"threadId":""')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_existing_thread_starts_turn_directly() {
	codexbot_ts_with_temp_db('codexbot_ts_existing_thread_turn.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		first_task := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_existing_thread_first'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_existing_thread_first'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_existing_thread_first'
			target:      'chat_codexbot_ts_existing_thread'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('first turn', 'chat_codexbot_ts_existing_thread',
				'om_codexbot_existing_thread_first')
		}) or { panic(err) }
		first_stream_id := codexbot_ts_first_stream_id(first_task.commands)
		assert first_stream_id != ''

		first_rpc := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_existing_thread_first_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_existing_001"},"has_error":false}'
		}) or { panic(err) }
		assert first_rpc.commands.len == 1
		assert first_rpc.commands[0].method == 'turn/start'
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_existing_thread_turn_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_existing_001"}},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_existing_thread_completed'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{}}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_existing_thread_read'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_existing_001","turns":[{"id":"turn_thread_existing_001","items":[{"type":"agentMessage","id":"item_thread_existing_001","text":"first turn done","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }

		second_task := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_existing_thread_second'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_existing_thread_second'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_existing_thread_second'
			target:      'chat_codexbot_ts_existing_thread'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('second turn', 'chat_codexbot_ts_existing_thread',
				'om_codexbot_existing_thread_second')
		}) or { panic(err) }
		assert second_task.handled
		assert second_task.commands.len == 1
		assert second_task.commands[0].type_ == 'provider.rpc.call'
		assert second_task.commands[0].method == 'turn/start'
		assert second_task.commands[0].params.contains('"threadId":"thread_existing_001"')
		assert second_task.commands[0].params.contains('"text":"second turn"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_reuses_thread_after_restart() {
	codexbot_ts_with_temp_db('codexbot_ts_reuse_thread.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor_a := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
		})
		defer {
			executor_a.close()
		}
		mut app := App{}
		first_task := executor_a.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_reuse_task_1'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_reuse_task_1'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_reuse_task_1'
			target:      'chat_codexbot_ts_reuse'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('first task', 'chat_codexbot_ts_reuse',
				'om_codexbot_reuse_task_1')
		}) or { panic(err) }
		first_stream_id := codexbot_ts_first_stream_id(first_task.commands)
		assert first_stream_id != ''
		_ := executor_a.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_reuse_rpc_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_reuse_001"},"has_error":false}'
		}) or { panic(err) }
		_ = executor_a.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_reuse_turn_rpc_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_reuse_001"}},"has_error":false}'
		}) or { panic(err) }
		_ = executor_a.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_reuse_completed_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{}}'
		}) or { panic(err) }
		_ = executor_a.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_reuse_read_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_reuse_001","turns":[{"id":"turn_thread_reuse_001","items":[{"type":"agentMessage","id":"item_thread_reuse_001","text":"reuse ok","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }

		mut executor_b := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
		})
		defer {
			executor_b.close()
		}
		second_task := executor_b.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_reuse_task_2'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_reuse_task_2'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_reuse_task_2'
			target:      'chat_codexbot_ts_reuse'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('second task', 'chat_codexbot_ts_reuse',
				'om_codexbot_reuse_task_2')
		}) or { panic(err) }
		assert second_task.handled
		assert second_task.commands.len == 1
		assert second_task.commands[0].type_ == 'provider.rpc.call'
		assert second_task.commands[0].method == 'turn/start'
		assert second_task.commands[0].params.contains('"threadId":"thread_reuse_001"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_recovers_when_reused_thread_is_missing() {
	codexbot_ts_with_temp_db('codexbot_ts_recover_missing_thread.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
		})
		defer {
			executor.close()
		}
		mut app := App{}
		first_task := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_recover_missing_thread_task_1'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_recover_missing_thread_task_1'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_recover_missing_thread_task_1'
			target:      'chat_codexbot_ts_recover_missing_thread'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('first task', 'chat_codexbot_ts_recover_missing_thread',
				'om_codexbot_recover_missing_thread_task_1')
		}) or { panic(err) }
		first_stream_id := codexbot_ts_first_stream_id(first_task.commands)
		assert first_stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_recover_missing_thread_rpc_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_recover_missing_001"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_recover_missing_thread_turn_rpc_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_recover_missing_001"}},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_recover_missing_thread_completed_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{}}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_recover_missing_thread_read_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_recover_missing_001","turns":[{"id":"turn_thread_recover_missing_001","items":[{"type":"agentMessage","id":"item_thread_recover_missing_001","text":"recover me","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }

		second_task := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_recover_missing_thread_task_2'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_recover_missing_thread_task_2'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_recover_missing_thread_task_2'
			target:      'chat_codexbot_ts_recover_missing_thread'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('follow up task', 'chat_codexbot_ts_recover_missing_thread',
				'om_codexbot_recover_missing_thread_task_2')
		}) or { panic(err) }
		assert second_task.handled
		assert second_task.commands.len == 1
		assert second_task.commands[0].method == 'turn/start'
		assert second_task.commands[0].params.contains('"threadId":"thread_recover_missing_001"')
		second_stream_id := codexbot_ts_first_stream_id(second_task.commands)
		assert second_stream_id != ''

		recover_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_recover_missing_thread_error'
			provider:   'codex'
			instance:   'main'
			trace_id:   second_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"codex.error_burst","result":["thread not found: thread_recover_missing_001"],"has_error":true}'
		}) or { panic(err) }
		assert recover_resp.handled
		assert recover_resp.commands.len == 2
		assert recover_resp.commands[0].type_ == 'provider.message.send'
		assert recover_resp.commands[0].content.contains('**Thread Restarting**')
		assert recover_resp.commands[0].content.contains('thread_recover_missing_001')
		assert recover_resp.commands[1].type_ == 'provider.rpc.call'
		assert recover_resp.commands[1].method == 'thread/start'
		assert !recover_resp.commands[1].params.contains('"threadId":"thread_recover_missing_001"')

		restart_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_recover_missing_thread_restart_ok'
			provider:   'codex'
			instance:   'main'
			trace_id:   second_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_recover_missing_002"},"has_error":false}'
		}) or { panic(err) }
		assert restart_resp.handled
		assert restart_resp.commands.len == 1
		assert restart_resp.commands[0].type_ == 'provider.rpc.call'
		assert restart_resp.commands[0].method == 'turn/start'
		assert restart_resp.commands[0].params.contains('"threadId":"thread_recover_missing_002"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_restores_stream_draft_after_restart() {
	codexbot_ts_with_temp_db('codexbot_ts_restore_draft.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor_a := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
		})
		defer {
			executor_a.close()
		}
		mut app := App{}
		task_resp := executor_a.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_restore_task_1'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_restore_task_1'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_restore_task_1'
			target:      'chat_codexbot_ts_restore'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('draft task', 'chat_codexbot_ts_restore',
				'om_codexbot_restore_task_1')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''
		first_delta := executor_a.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_restore_delta_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/agentMessage/delta","params":{"delta":"hello "}}'
		}) or { panic(err) }
		assert first_delta.handled
		assert first_delta.commands.len == 2
		assert first_delta.commands[0].type_ == 'provider.message.send'
		assert first_delta.commands[1].type_ == 'stream.append'
		assert first_delta.commands[1].text == 'hello '
		item_stream_id := first_delta.commands[1].stream_id
		assert item_stream_id != ''
		assert item_stream_id == first_delta.commands[0].stream_id

		mut executor_b := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
		})
		defer {
			executor_b.close()
		}
		second_delta := executor_b.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_restore_delta_2'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/agentMessage/delta","params":{"delta":"world"}}'
		}) or { panic(err) }
		assert second_delta.handled
		assert second_delta.commands.len == 1
		assert second_delta.commands[0].type_ == 'stream.append'
		assert second_delta.commands[0].stream_id == item_stream_id
		assert second_delta.commands[0].text == 'world'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_persists_completed_stream_snapshot() {
	codexbot_ts_with_temp_db('codexbot_ts_completed_snapshot.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_completed_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_completed_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_completed_task'
			target:      'chat_codexbot_ts_completed'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('finish task', 'chat_codexbot_ts_completed',
				'om_codexbot_completed_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_completed_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_completed_001"},"has_error":false}'
		}) or { panic(err) }

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_completed_delta_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/agentMessage/delta","params":{"delta":"hello "}}'
		}) or { panic(err) }
		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_completed_delta_2'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/agentMessage/delta","params":{"delta":"world"}}'
		}) or { panic(err) }
		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_completed_done'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{}}'
		}) or { panic(err) }

		req := http.Request{
			method: .get
			url:    '/admin/state'
			host:   'example.test'
		}
		outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         req
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_completed_state'
			request_id:  'req_codexbot_ts_completed_state'
		}) or { panic(err) }
		assert outcome.response.status == 200
		assert outcome.response.body.contains('"threadId":"thread_completed_001"')
		assert outcome.response.body.contains('"streamId":"' + stream_id + '"')
		assert outcome.response.body.contains('"status":"completed"')
		assert outcome.response.body.contains('"resultText":"hello world"')
		assert outcome.response.body.contains('"lastEvent":"turn/completed"')
		assert !outcome.response.body.contains('"completedAt":0')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_uses_content_array_message_before_idle() {
	codexbot_ts_with_temp_db('codexbot_ts_content_array.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_content_array_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_content_array_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_content_array_task'
			target:      'chat_codexbot_ts_content_array'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('content array task', 'chat_codexbot_ts_content_array',
				'om_codexbot_content_array_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''
		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_content_array_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_content_array_001"},"has_error":false}'
		}) or { panic(err) }
		message_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_content_array_message'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/completed","params":{"item":{"content":[{"type":"output_text","text":"final answer from content array"}]}}}'
		}) or { panic(err) }
		assert message_resp.handled
		assert message_resp.commands.len == 3
		assert message_resp.commands[0].type_ == 'provider.message.send'
		assert message_resp.commands[1].type_ == 'stream.append'
		assert message_resp.commands[1].text == 'final answer from content array'
		assert message_resp.commands[2].type_ == 'stream.finish'
		assert message_resp.commands[2].stream_id == message_resp.commands[1].stream_id
		idle_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_content_array_idle'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
		}) or { panic(err) }
		assert idle_resp.handled
		assert idle_resp.commands.len == 0
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_does_not_echo_user_message_item_completed() {
	codexbot_ts_with_temp_db('codexbot_ts_user_message_item_completed.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_user_message_item_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_user_message_item_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_user_message_item_task'
			target:      'chat_codexbot_ts_user_message_item'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('我刚才改了什么?', 'chat_codexbot_ts_user_message_item',
				'om_codexbot_user_message_item_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_user_message_item_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_user_message_item_001"},"has_error":false}'
		}) or { panic(err) }

		user_item_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_user_message_item_completed'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/completed","params":{"threadId":"thread_user_message_item_001","turnId":"turn_user_message_item_001","item":{"id":"item_user_message_item_001","type":"userMessage","content":[{"type":"text","text":"我刚才改了什么?","text_elements":[]}]}}}'
		}) or { panic(err) }
		assert user_item_resp.handled
		assert user_item_resp.commands.len == 0

		assistant_item_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_user_message_item_answer'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/completed","params":{"threadId":"thread_user_message_item_001","turnId":"turn_user_message_item_001","item":{"id":"item_user_message_item_002","type":"agentMessage","phase":"final_answer","text":"这是 assistant 的答案。"}}}'
		}) or { panic(err) }
		assert assistant_item_resp.handled
		assert assistant_item_resp.commands.len == 3
		assert assistant_item_resp.commands[0].type_ == 'provider.message.send'
		assert assistant_item_resp.commands[1].type_ == 'stream.append'
		assert assistant_item_resp.commands[1].text == '这是 assistant 的答案。'
		assert assistant_item_resp.commands[2].type_ == 'stream.finish'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_turn_completed_falls_back_to_thread_read() {
	codexbot_ts_with_temp_db('codexbot_ts_turn_completed_thread_read.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_turn_completed_thread_read_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_turn_completed_thread_read_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_turn_completed_thread_read_task'
			target:      'chat_codexbot_ts_turn_completed_thread_read'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('hello', 'chat_codexbot_ts_turn_completed_thread_read',
				'om_codexbot_turn_completed_thread_read_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_turn_completed_thread_read_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_thread_read_001"},"has_error":false}'
		}) or { panic(err) }

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_turn_completed_thread_read_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_thread_read_001"}},"has_error":false}'
		}) or { panic(err) }

		completed_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_turn_completed_thread_read_completed'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{"threadId":"thread_thread_read_001","turn":{"id":"turn_thread_read_001","items":[],"status":"completed","error":null}}}'
		}) or { panic(err) }
		assert completed_resp.handled
		assert completed_resp.commands.len == 0
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_turn_completed_prefers_final_message_from_turn_items() {
	codexbot_ts_with_temp_db('codexbot_ts_turn_completed_turn_items.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_turn_completed_turn_items_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_turn_completed_turn_items_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_turn_completed_turn_items_task'
			target:      'chat_codexbot_ts_turn_completed_turn_items'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('hello', 'chat_codexbot_ts_turn_completed_turn_items',
				'om_codexbot_turn_completed_turn_items_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_turn_completed_turn_items_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_turn_items_001"},"has_error":false}'
		}) or { panic(err) }

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_turn_completed_turn_items_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_turn_items_001"}},"has_error":false}'
		}) or { panic(err) }

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_turn_completed_turn_items_delta'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/agentMessage/delta","params":{"threadId":"thread_turn_items_001","turnId":"turn_turn_items_001","delta":"draft commentary"}}'
		}) or { panic(err) }

		completed_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_turn_completed_turn_items_completed'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{"threadId":"thread_turn_items_001","turn":{"id":"turn_turn_items_001","items":[{"type":"agentMessage","id":"item_turn_items_001","phase":"commentary","text":"draft commentary"},{"type":"agentMessage","id":"item_turn_items_002","phase":"final_answer","text":"final answer from turn items"}],"status":"completed","error":null}}}'
		}) or { panic(err) }
		assert completed_resp.handled
		assert completed_resp.commands.len >= 1

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_turn_completed_turn_items_state'
			request_id:  'req_codexbot_ts_turn_completed_turn_items_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"status":"completed"')
		assert state_resp.response.body.contains('draft commentary')
		assert state_resp.response.body.contains('final answer from turn items')
		assert state_resp.response.body.contains('"lastEvent":"turn/completed"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_read_preserves_multiple_assistant_items() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_read_multi_items.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_read_multi_items_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_read_multi_items_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_read_multi_items_task'
			target:      'chat_codexbot_ts_thread_read_multi_items'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('我们到哪儿了？', 'chat_codexbot_ts_thread_read_multi_items',
				'om_codexbot_thread_read_multi_items_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_multi_items_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_read_multi_items_001"},"has_error":false}'
		}) or { panic(err) }

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_multi_items_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_read_multi_items_001"}},"has_error":false}'
		}) or { panic(err) }

		read_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_multi_items_read'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_read_multi_items_001","turns":[{"id":"turn_read_multi_items_001","items":[{"type":"agentMessage","id":"item_read_multi_items_001","text":"第一条 item","phase":"commentary","memoryCitation":null},{"type":"agentMessage","id":"item_read_multi_items_002","text":"第二条 item","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 3
		assert read_resp.commands[0].type_ == 'provider.message.send'
		assert read_resp.commands[1].type_ == 'stream.append'
		assert read_resp.commands[1].text == '第一条 item\n\n第二条 item'
		assert read_resp.commands[2].type_ == 'stream.finish'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_persists_turn_id_from_delta_notification() {
	codexbot_ts_with_temp_db('codexbot_ts_turn_id_delta.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_turn_id_delta_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_turn_id_delta_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_turn_id_delta_task'
			target:      'chat_codexbot_ts_turn_id_delta'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('delta turn id task', 'chat_codexbot_ts_turn_id_delta',
				'om_codexbot_turn_id_delta_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_turn_id_delta_notif'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/agentMessage/delta","params":{"threadId":"thread_turn_id_delta_001","turnId":"turn_turn_id_delta_001","itemId":"item_turn_id_delta_001","delta":"hello from turn id"}}'
		}) or { panic(err) }

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_turn_id_delta_state'
			request_id:  'req_codexbot_ts_turn_id_delta_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"turnId":"turn_turn_id_delta_001"')
		assert state_resp.response.body.contains('"threadId":"thread_turn_id_delta_001"')
		assert state_resp.response.body.contains('"draft":"hello from turn id"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_raw_response_final_answer_completes_stream() {
	codexbot_ts_with_temp_db('codexbot_ts_raw_response_final.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_raw_response_final_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_raw_response_final_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_raw_response_final_task'
			target:      'chat_codexbot_ts_raw_response_final'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('raw response final task', 'chat_codexbot_ts_raw_response_final',
				'om_codexbot_raw_response_final_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		final_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_raw_response_final_notif'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"rawResponseItem/completed","params":{"threadId":"thread_raw_final_001","turnId":"turn_raw_final_001","item":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"final answer from raw response"}]}}}'
		}) or { panic(err) }
		assert final_resp.handled
		assert final_resp.commands.len == 3
		assert final_resp.commands[0].type_ == 'provider.message.send'
		assert final_resp.commands[1].type_ == 'stream.append'
		assert final_resp.commands[1].text == 'final answer from raw response'
		assert final_resp.commands[2].type_ == 'stream.finish'
		assert final_resp.commands[2].stream_id == final_resp.commands[1].stream_id

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_raw_response_final_state'
			request_id:  'req_codexbot_ts_raw_response_final_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"turnId":"turn_raw_final_001"')
		assert state_resp.response.body.contains('"status":"completed"')
		assert state_resp.response.body.contains('"resultText":"final answer from raw response"')
		assert state_resp.response.body.contains('"lastEvent":"rawResponseItem/completed"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_commentary_after_final_answer_does_not_replace_parent_answer() {
	codexbot_ts_with_temp_db('codexbot_ts_commentary_after_final.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_commentary_after_final_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_commentary_after_final_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_commentary_after_final_task'
			target:      'chat_codexbot_ts_commentary_after_final'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('commentary after final task', 'chat_codexbot_ts_commentary_after_final',
				'om_codexbot_commentary_after_final_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		final_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_commentary_after_final_final'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/completed","params":{"threadId":"thread_commentary_after_final_001","turnId":"turn_commentary_after_final_001","item":{"id":"item_commentary_after_final_001","type":"agentMessage","phase":"final_answer","text":"stable final answer"}}}'
		}) or { panic(err) }
		assert final_resp.handled
		assert final_resp.commands.len == 3
		assert final_resp.commands[0].type_ == 'provider.message.send'
		assert final_resp.commands[1].type_ == 'stream.append'
		assert final_resp.commands[1].text == 'stable final answer'
		assert final_resp.commands[2].type_ == 'stream.finish'
		assert final_resp.commands[1].stream_id == stream_id

		commentary_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_commentary_after_final_commentary'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/completed","params":{"threadId":"thread_commentary_after_final_001","turnId":"turn_commentary_after_final_001","item":{"id":"item_commentary_after_final_002","type":"agentMessage","phase":"commentary","text":"this commentary should not replace the answer"}}}'
		}) or { panic(err) }
		assert commentary_resp.handled
		assert commentary_resp.commands.len == 0

		idle_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_commentary_after_final_idle'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"thread/status/changed","params":{"threadId":"thread_commentary_after_final_001","status":{"type":"idle"}}}'
		}) or { panic(err) }
		assert idle_resp.handled
		assert idle_resp.commands.len == 0

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_commentary_after_final_state'
			request_id:  'req_codexbot_ts_commentary_after_final_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"resultText":"stable final answer"')
		assert !state_resp.response.body.contains('this commentary should not replace the answer')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_persists_thread_path_from_thread_start_response() {
	codexbot_ts_with_temp_db('codexbot_ts_idle_status.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
		})
		defer {
			executor.close()
		}
		mut app := App{}
		session_dir := os.join_path(os.temp_dir(), 'vhttpd_codexbot_ts_idle_status')
		os.mkdir_all(session_dir) or { panic(err) }
		session_file := os.join_path(session_dir, 'session.jsonl')
		os.write_file(session_file, '{"timestamp":"2026-03-27T14:00:02.896Z","type":"event_msg","payload":{"type":"agent_message","message":"final answer from session","phase":"final_answer"}}\n') or {
			panic(err)
		}
		defer {
			os.rm(session_file) or {}
			os.rmdir(session_dir) or {}
		}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_idle_status_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_idle_status_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_idle_status_task'
			target:      'chat_codexbot_ts_idle_status'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('idle status task', 'chat_codexbot_ts_idle_status',
				'om_codexbot_idle_status_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:
				'{"method":"thread/start","result":{"threadId":"thread_idle_001","thread":{"path":"' +
				session_file.replace('\\', '\\\\').replace('"', '\\"') + '"}},"has_error":false}'
		}) or { panic(err) }
		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_idle_001"}},"has_error":false}'
		}) or { panic(err) }
		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_idle_status_state'
			request_id:  'req_codexbot_ts_idle_status_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains(stream_id)
		assert state_resp.response.body.contains('thread_idle_001')
		assert state_resp.response.body.contains(session_file)
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_idle_status_resolves_session_from_thread_id() {
	codexbot_ts_with_temp_db('codexbot_ts_idle_status_lookup.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		session_root := os.join_path(os.temp_dir(), 'vhttpd_codex_sessions_test')
		session_day := os.join_path(session_root, '2026', '03', '27')
		os.mkdir_all(session_day) or { panic(err) }
		prev_root := os.getenv('VHTTPD_CODEX_SESSIONS_ROOT')
		os.setenv('VHTTPD_CODEX_SESSIONS_ROOT', session_root, true)
		defer {
			if prev_root == '' {
				os.setenv('VHTTPD_CODEX_SESSIONS_ROOT', '', true)
			} else {
				os.setenv('VHTTPD_CODEX_SESSIONS_ROOT', prev_root, true)
			}
			os.rmdir_all(session_root) or {}
		}
		thread_id := '019d2f8a-0265-71f2-b541-cc2d94783ec0'
		session_file := os.join_path(session_day, 'rollout-2026-03-27T21-44-26-' + thread_id +
			'.jsonl')
		os.write_file(session_file, '{"timestamp":"2026-03-27T14:00:02.896Z","turnId":"turn_idle_lookup_001","type":"event_msg","payload":{"type":"agent_message","message":"final answer from session lookup","phase":"final_answer"}}\n') or {
			panic(err)
		}

		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_idle_status_lookup_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_idle_status_lookup_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_idle_status_lookup_task'
			target:      'chat_codexbot_ts_idle_status_lookup'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('idle status lookup task', 'chat_codexbot_ts_idle_status_lookup',
				'om_codexbot_idle_status_lookup_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_lookup_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"' + thread_id +
				'"},"has_error":false}'
		}) or { panic(err) }
		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_lookup_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_idle_lookup_001"}},"has_error":false}'
		}) or { panic(err) }
		idle_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_lookup_idle'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
		}) or { panic(err) }
		assert idle_resp.handled
		assert idle_resp.commands.len == 3
		assert idle_resp.commands[0].type_ == 'provider.message.send'
		assert idle_resp.commands[1].type_ == 'stream.append'
		assert idle_resp.commands[1].text == 'final answer from session lookup'
		assert idle_resp.commands[2].type_ == 'stream.finish'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_idle_status_after_commentary_still_reads_thread_final() {
	codexbot_ts_with_temp_db('codexbot_ts_idle_status_commentary.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_idle_status_commentary_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_idle_status_commentary_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_idle_status_commentary_task'
			target:      'chat_codexbot_ts_idle_status_commentary'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('summarize current progress', 'chat_codexbot_ts_idle_status_commentary',
				'om_codexbot_idle_status_commentary_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_commentary_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_idle_commentary_001"},"has_error":false}'
		}) or { panic(err) }
		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_commentary_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_idle_commentary_001"}},"has_error":false}'
		}) or { panic(err) }
		commentary_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_commentary_item'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/completed","params":{"threadId":"thread_idle_commentary_001","turnId":"turn_idle_commentary_001","item":{"id":"item_idle_commentary_001","type":"agentMessage","phase":"commentary","text":"commentary only so far"}}}'
		}) or { panic(err) }
		assert commentary_resp.handled

		idle_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_commentary_idle'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"thread/status/changed","params":{"threadId":"thread_idle_commentary_001","status":{"type":"idle"}}}'
		}) or { panic(err) }
		assert idle_resp.handled
		assert idle_resp.commands.len == 1
		assert idle_resp.commands[0].type_ == 'provider.rpc.call'
		assert idle_resp.commands[0].method == 'thread/read'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_idle_status_prefers_richer_session_answer_over_partial_thread_read() {
	codexbot_ts_with_temp_db('codexbot_ts_idle_status_partial_thread_read.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		session_dir := os.join_path(os.temp_dir(), 'vhttpd_codexbot_ts_idle_partial')
		os.mkdir_all(session_dir) or { panic(err) }
		session_file := os.join_path(session_dir, 'session.jsonl')
		os.write_file(session_file, '{"timestamp":"2026-03-31T12:00:00.000Z","turnId":"turn_idle_partial_001","type":"event_msg","payload":{"type":"agent_message","message":"第一段。\\n\\n第二段。\\n\\n第三段。","phase":"final_answer"}}\n') or {
			panic(err)
		}
		defer {
			os.rm(session_file) or {}
			os.rmdir(session_dir) or {}
		}

		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_idle_status_partial_thread_read_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_idle_status_partial_thread_read_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_idle_status_partial_thread_read_task'
			target:      'chat_codexbot_ts_idle_status_partial_thread_read'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('where are we now?', 'chat_codexbot_ts_idle_status_partial_thread_read',
				'om_codexbot_idle_status_partial_thread_read_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_partial_thread_read_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:
				'{"method":"thread/start","result":{"threadId":"thread_idle_partial_001","thread":{"path":"' +
				session_file.replace('\\', '\\\\').replace('"', '\\"') + '"}},"has_error":false}'
		}) or { panic(err) }
		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_partial_thread_read_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_idle_partial_001"}},"has_error":false}'
		}) or { panic(err) }
		partial_read_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_partial_thread_read_read'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_idle_partial_001","turns":[{"id":"turn_idle_partial_001","items":[{"type":"agentMessage","id":"item_idle_partial_001","text":"第一段。","phase":"commentary","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }
		assert partial_read_resp.handled
		assert partial_read_resp.commands.len == 3
		assert partial_read_resp.commands[0].type_ == 'provider.message.send'
		assert partial_read_resp.commands[1].type_ == 'stream.append'
		assert partial_read_resp.commands[1].text == '第一段。'
		assert partial_read_resp.commands[2].type_ == 'stream.finish'

		idle_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_partial_thread_read_idle'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"thread/status/changed","params":{"threadId":"thread_idle_partial_001","status":{"type":"idle"}}}'
		}) or { panic(err) }
		assert idle_resp.handled
		assert idle_resp.commands.len == 2
		assert idle_resp.commands[0].type_ == 'stream.append'
		assert idle_resp.commands[0].text == '\n\n第二段。\n\n第三段。'
		assert idle_resp.commands[1].type_ == 'stream.finish'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_idle_status_uses_current_turn_session_answer_only() {
	codexbot_ts_with_temp_db('codexbot_ts_idle_status_current_turn_only.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			executor.close()
		}
		mut app := App{}
		session_dir := os.join_path(os.temp_dir(), 'vhttpd_codexbot_ts_idle_turn_filtered')
		os.mkdir_all(session_dir) or { panic(err) }
		session_file := os.join_path(session_dir, 'session.jsonl')
		os.write_file(session_file,
			'{"timestamp":"2026-03-31T12:00:00.000Z","turnId":"turn_idle_old_001","type":"event_msg","payload":{"type":"agent_message","message":"上一轮最后一条","phase":"final_answer"}}\n' +
			'{"timestamp":"2026-03-31T12:01:00.000Z","turnId":"turn_idle_current_001","type":"event_msg","payload":{"type":"agent_message","message":"当前这一轮的新答案","phase":"final_answer"}}\n'
		) or {
			panic(err)
		}
		defer {
			os.rm(session_file) or {}
			os.rmdir(session_dir) or {}
		}

		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_idle_status_turn_filtered_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_idle_status_turn_filtered_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_idle_status_turn_filtered_task'
			target:      'chat_codexbot_ts_idle_status_turn_filtered'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('我们到哪儿了？', 'chat_codexbot_ts_idle_status_turn_filtered',
				'om_codexbot_idle_status_turn_filtered_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_turn_filtered_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:
				'{"method":"thread/start","result":{"threadId":"thread_idle_turn_filtered_001","thread":{"path":"' +
				session_file.replace('\\', '\\\\').replace('"', '\\"') + '"}},"has_error":false}'
		}) or { panic(err) }
		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_turn_filtered_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_idle_current_001"}},"has_error":false}'
		}) or { panic(err) }
		idle_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_idle_status_turn_filtered_idle'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"thread/status/changed","params":{"threadId":"thread_idle_turn_filtered_001","turnId":"turn_idle_current_001","status":{"type":"idle"}}}'
		}) or { panic(err) }
		assert idle_resp.handled
		assert idle_resp.commands.len == 3
		assert idle_resp.commands[0].type_ == 'provider.message.send'
		assert idle_resp.commands[1].type_ == 'stream.append'
		assert idle_resp.commands[1].text == '当前这一轮的新答案'
		assert idle_resp.commands[2].type_ == 'stream.finish'

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_idle_status_turn_filtered_state'
			request_id:  'req_codexbot_ts_idle_status_turn_filtered_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"resultText":"当前这一轮的新答案"')
		assert !state_resp.response.body.contains('"resultText":"上一轮最后一条"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_persists_error_stream_snapshot() {
	codexbot_ts_with_temp_db('codexbot_ts_error_snapshot.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_error_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_error_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_error_task'
			target:      'chat_codexbot_ts_error'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('broken task', 'chat_codexbot_ts_error',
				'om_codexbot_error_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		error_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_error_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{},"has_error":true}'
		}) or { panic(err) }
		assert error_resp.handled
		assert error_resp.commands.len == 1
		assert error_resp.commands[0].content.contains('**Codex RPC Error**')
		assert error_resp.commands[0].content.contains('Method: `thread/start`')

		req := http.Request{
			method: .get
			url:    '/admin/state'
			host:   'example.test'
		}
		outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         req
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_error_state'
			request_id:  'req_codexbot_ts_error_state'
		}) or { panic(err) }
		assert outcome.response.status == 200
		assert outcome.response.body.contains('"streamId":"' + stream_id + '"')
		assert outcome.response.body.contains('"status":"error"')
		assert outcome.response.body.contains('Codex RPC Error')
		assert outcome.response.body.contains('thread/start')
		assert outcome.response.body.contains('"lastEvent":"thread/start"')
		assert !outcome.response.body.contains('"completedAt":0')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_error_burst_surfaces_details() {
	codexbot_ts_with_temp_db('codexbot_ts_error_burst.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
		})
		defer {
			executor.close()
		}
		mut app := App{}
		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_error_burst_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_error_burst_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_error_burst_task'
			target:      'chat_codexbot_ts_error_burst'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('burst task', 'chat_codexbot_ts_error_burst',
				'om_codexbot_error_burst_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		error_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_error_burst_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"codex.error_burst","result":["{\\"method\\":\\"thread/status/changed\\",\\"params\\":{\\"threadId\\":\\"thread_error_burst_001\\",\\"status\\":{\\"type\\":\\"systemError\\"}}}"],"has_error":true}'
		}) or { panic(err) }
		assert error_resp.handled
		assert error_resp.commands.len == 1
		assert error_resp.commands[0].type_ == 'provider.message.send'
		assert error_resp.commands[0].content.contains('**Codex RPC Error**')
		assert error_resp.commands[0].content.contains('Method: `codex.error_burst`')
		assert error_resp.commands[0].content.contains('systemError')
	})
}
