module main

import net.http
import os
import time

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_handles_help_and_task_flow() {
	codexbot_ts_with_temp_db('codexbot_ts_help_and_task.sqlite', fn (_ string) {
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
		help_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_help'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_help'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_help'
			target:      'chat_codexbot_ts'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/help', 'chat_codexbot_ts', 'om_codexbot_help')
		}) or { panic(err) }
		assert help_resp.handled
		assert help_resp.commands.len == 1
		assert help_resp.commands[0].type_ == 'provider.message.send'
		assert help_resp.commands[0].provider == 'feishu'
		assert help_resp.commands[0].text.contains('/project [project_key]')

		task_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_task'
			target:      'chat_codexbot_ts'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('please inspect this bug', 'chat_codexbot_ts',
				'om_codexbot_task')
		}) or { panic(err) }
		assert task_resp.handled
		assert task_resp.commands.len == 1
		assert task_resp.commands[0].type_ == 'provider.rpc.call'
		assert task_resp.commands[0].provider == 'codex'
		assert task_resp.commands[0].method == 'thread/start'
		assert task_resp.commands[0].stream_id.starts_with('codex:ts_')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_handles_codex_callbacks() {
	codexbot_ts_with_temp_db('codexbot_ts_callbacks.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_task_2'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_task_2'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_task_2'
			target:      'chat_codexbot_ts_2'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('run a task', 'chat_codexbot_ts_2',
				'om_codexbot_task_2')
		}) or { panic(err) }
		stream_id := codexbot_ts_first_stream_id(task_resp.commands)
		assert stream_id != ''

		rpc_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_ts_001"},"has_error":false}'
		}) or { panic(err) }
		assert rpc_resp.handled
		assert rpc_resp.commands.len == 1
		assert rpc_resp.commands[0].type_ == 'provider.rpc.call'
		assert rpc_resp.commands[0].method == 'turn/start'
		assert rpc_resp.commands[0].stream_id == stream_id

		turn_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_turn_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_ts_001"}},"has_error":false}'
		}) or { panic(err) }
		assert turn_resp.handled
		assert turn_resp.commands.len == 0

		notif_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_notif'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/agentMessage/delta","params":{"delta":"hello from codex"}}'
		}) or { panic(err) }
		assert notif_resp.handled
		assert notif_resp.commands.len == 2
		assert notif_resp.commands[0].type_ == 'provider.message.send'
		assert notif_resp.commands[0].stream_id != ''
		assert notif_resp.commands[0].stream_id != stream_id
		assert notif_resp.commands[1].type_ == 'stream.append'
		assert notif_resp.commands[1].stream_id == notif_resp.commands[0].stream_id
		assert notif_resp.commands[1].text == 'hello from codex'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_active_status_keeps_running_without_overwriting_message() {
	codexbot_ts_with_temp_db('codexbot_ts_active_status.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_active_status_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_active_status_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_active_status_task'
			target:      'chat_codexbot_ts_active_status'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('run active status task', 'chat_codexbot_ts_active_status',
				'om_codexbot_active_status_task')
		}) or { panic(err) }
		stream_id := codexbot_ts_first_stream_id(task_resp.commands)
		assert stream_id != ''

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_active_status_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_active_001"},"has_error":false}'
		}) or { panic(err) }

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_active_status_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_active_001"}},"has_error":false}'
		}) or { panic(err) }

		active_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_active_status_notif'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"thread/status/changed","params":{"threadId":"thread_active_001","status":{"type":"active","activeFlags":[]}}}'
		}) or { panic(err) }
		assert active_resp.handled
		assert active_resp.commands.len == 0

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_active_status_state'
			request_id:  'codexbot_ts_active_status_state'
		}) or { panic(err) }
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"status":"running"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_ignores_feishu_message_read_events() {
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
	resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
		mode:        'websocket_upstream'
		event:       'event'
		id:          'codexbot_ts_feishu_read'
		provider:    'feishu'
		instance:    'main'
		trace_id:    'trace_codexbot_ts_feishu_read'
		event_type:  'im.message.message_read_v1'
		message_id:  ''
		target:      ''
		target_type: ''
		payload:     '{"schema":"2.0","header":{"event_type":"im.message.message_read_v1"}}'
		metadata:    {
			'event_id': 'evt_message_read_001'
		}
	}) or { panic(err) }
	assert !resp.handled
	assert resp.commands.len == 0
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_message_read_after_codex_notification_stays_safe() {
	codexbot_ts_with_temp_db('codexbot_ts_read_after_notif.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    2
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
			id:          'codexbot_ts_task_3'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_task_3'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_task_3'
			target:      'chat_codexbot_ts_3'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('run another task', 'chat_codexbot_ts_3',
				'om_codexbot_task_3')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		notif_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_started'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"thread/started","params":{"thread":{"id":"thread_ts_003","status":{"type":"idle"}}}}'
		}) or { panic(err) }
		assert notif_resp.handled
		assert notif_resp.commands.len == 1
		assert notif_resp.commands[0].type_ == 'provider.rpc.call'
		assert notif_resp.commands[0].method == 'turn/start'
		assert notif_resp.commands[0].params.contains('"threadId":"thread_ts_003"')

		read_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'event'
			id:          'codexbot_ts_feishu_read_after_notif'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_feishu_read_after_notif'
			event_type:  'im.message.message_read_v1'
			message_id:  ''
			target:      ''
			target_type: ''
			payload:     '{"schema":"2.0","header":{"event_type":"im.message.message_read_v1"}}'
			metadata:    {
				'event_id': 'evt_message_read_after_notif_001'
			}
		}) or { panic(err) }
		assert !read_resp.handled
		assert read_resp.commands.len == 0
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_and_new_commands_show_session_state() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_cmd.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_thread_cmd_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_cmd_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_cmd_task'
			target:      'chat_codexbot_ts_thread_cmd'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('thread aware task', 'chat_codexbot_ts_thread_cmd',
				'om_codexbot_thread_cmd_task')
		}) or { panic(err) }
		stream_id := codexbot_ts_first_stream_id(task_resp.commands)
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_cmd_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_cmd_001"},"has_error":false}'
		}) or { panic(err) }

		thread_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_cmd_query'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_cmd_query'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_cmd_query'
			target:      'chat_codexbot_ts_thread_cmd'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/thread', 'chat_codexbot_ts_thread_cmd',
				'om_codexbot_thread_cmd_query')
		}) or { panic(err) }
		assert thread_resp.handled
		assert thread_resp.commands.len == 1
		assert thread_resp.commands[0].text.contains('Current thread: `thread_cmd_001`')
		assert thread_resp.commands[0].text.contains('Last Stream: `' + stream_id + '`')
		assert thread_resp.commands[0].text.contains('Last Status: `starting_turn`')

		new_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_cmd_new'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_cmd_new'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_cmd_new'
			target:      'chat_codexbot_ts_thread_cmd'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/new', 'chat_codexbot_ts_thread_cmd',
				'om_codexbot_thread_cmd_new')
		}) or { panic(err) }
		assert new_resp.handled
		assert new_resp.commands.len == 1
		assert new_resp.commands[0].text.contains('**New Conversation**')
		assert new_resp.commands[0].text.contains('Previous Thread: `thread_cmd_001`')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_rejects_parallel_task_in_same_chat() {
	codexbot_ts_with_temp_db('codexbot_ts_busy_guard.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_busy_first'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_busy_first'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_busy_first'
			target:      'chat_codexbot_ts_busy'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('first active task', 'chat_codexbot_ts_busy',
				'om_codexbot_busy_first')
		}) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'
		assert first_resp.commands[0].stream_id != ''

		second_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_busy_second'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_busy_second'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_busy_second'
			target:      'chat_codexbot_ts_busy'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('second overlapping task', 'chat_codexbot_ts_busy',
				'om_codexbot_busy_second')
		}) or { panic(err) }
		assert second_resp.handled
		assert second_resp.commands.len == 1
		assert second_resp.commands[0].type_ == 'provider.message.send'
		assert second_resp.commands[0].stream_id == ''
		assert second_resp.commands[0].text.contains('Still working on the previous request.')
		assert second_resp.commands[0].text.contains('`/cancel`')

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_busy_state'
			request_id:  'req_codexbot_ts_busy_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('first active task')
		assert !state_resp.response.body.contains('second overlapping task')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_dedupes_replayed_feishu_message() {
	codexbot_ts_with_temp_db('codexbot_ts_feishu_dedup.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_dedup_first'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_dedup_first'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_dedup_same'
			target:      'chat_codexbot_ts_dedup'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('dedupe this inbound event', 'chat_codexbot_ts_dedup',
				'om_codexbot_dedup_same')
		}) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'
		assert first_resp.commands[0].stream_id != ''

		replay_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_dedup_replay'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_dedup_replay'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_dedup_same'
			target:      'chat_codexbot_ts_dedup'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('dedupe this inbound event', 'chat_codexbot_ts_dedup',
				'om_codexbot_dedup_same')
		}) or { panic(err) }
		assert replay_resp.handled
		assert replay_resp.commands.len == 0

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_dedup_state'
			request_id:  'req_codexbot_ts_dedup_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('dedupe this inbound event')
		assert state_resp.response.body.split('dedupe this inbound event').len == 2
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_dedupes_replayed_feishu_message_across_lanes() {
	codexbot_ts_with_temp_db('codexbot_ts_feishu_dedup_across_lanes.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    2
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
			id:          'codexbot_ts_dedup_lane_first'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_dedup_lane_first'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_dedup_lane_same'
			target:      'chat_codexbot_ts_dedup_lane'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('dedupe this inbound event across lanes',
				'chat_codexbot_ts_dedup_lane', 'om_codexbot_dedup_lane_same')
		}) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'
		assert first_resp.commands[0].stream_id != ''

		replay_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_dedup_lane_replay'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_dedup_lane_replay'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_dedup_lane_same'
			target:      'chat_codexbot_ts_dedup_lane'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('dedupe this inbound event across lanes',
				'chat_codexbot_ts_dedup_lane', 'om_codexbot_dedup_lane_same')
		}) or { panic(err) }
		assert replay_resp.handled
		assert replay_resp.commands.len == 0
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_dedupes_replayed_feishu_message_by_event_id() {
	codexbot_ts_with_temp_db('codexbot_ts_feishu_dedup_event_id.sqlite', fn (_ string) {
		app_file := codexbot_ts_app_file()
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    2
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
			id:          'codexbot_ts_dedup_event_first'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_dedup_event_first'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_dedup_event_first'
			target:      'chat_codexbot_ts_dedup_event'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload_with_event('dedupe this inbound event by event id',
				'chat_codexbot_ts_dedup_event', 'om_codexbot_dedup_event_first', 'evt_codexbot_dedup_event',
				'1710000000')
		}) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'
		assert first_resp.commands[0].stream_id != ''

		replay_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_dedup_event_replay'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_dedup_event_replay'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_dedup_event_second'
			target:      'chat_codexbot_ts_dedup_event'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload_with_event('dedupe this inbound event by event id',
				'chat_codexbot_ts_dedup_event', 'om_codexbot_dedup_event_second', 'evt_codexbot_dedup_event',
				'1710000000')
		}) or { panic(err) }
		assert replay_resp.handled
		assert replay_resp.commands.len == 0
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_scopes_sessions_by_feishu_thread_root() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_scope.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_thread_scope_first'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_scope_first'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_scope_first'
			target:      'chat_codexbot_ts_thread_scope'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_thread_payload('thread A task', 'chat_codexbot_ts_thread_scope',
				'om_codexbot_thread_scope_first', 'om_thread_root_A', 'om_thread_parent_A')
		}) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'
		assert first_resp.commands[0].method == 'thread/start'
		assert first_resp.commands[0].stream_id != ''

		second_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_scope_second'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_scope_second'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_scope_second'
			target:      'chat_codexbot_ts_thread_scope'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_thread_payload('thread B task', 'chat_codexbot_ts_thread_scope',
				'om_codexbot_thread_scope_second', 'om_thread_root_B', 'om_thread_parent_B')
		}) or { panic(err) }
		assert second_resp.handled
		assert second_resp.commands.len == 1
		assert second_resp.commands[0].type_ == 'provider.rpc.call'
		assert second_resp.commands[0].method == 'thread/start'
		assert second_resp.commands[0].stream_id != ''

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_thread_scope_state'
			request_id:  'req_codexbot_ts_thread_scope_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"sessionKey":"chat_codexbot_ts_thread_scope::thread:om_thread_root_A"')
		assert state_resp.response.body.contains('"sessionKey":"chat_codexbot_ts_thread_scope::thread:om_thread_root_B"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_stale_busy_stream_does_not_block_next_prompt() {
	prev_stale := os.getenv('CODEXBOT_TS_ACTIVE_STREAM_STALE_MS')
	os.setenv('CODEXBOT_TS_ACTIVE_STREAM_STALE_MS', '1', true)
	defer {
		if prev_stale == '' {
			os.unsetenv('CODEXBOT_TS_ACTIVE_STREAM_STALE_MS')
		} else {
			os.setenv('CODEXBOT_TS_ACTIVE_STREAM_STALE_MS', prev_stale, true)
		}
	}
	codexbot_ts_with_temp_db('codexbot_ts_stale_busy.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_stale_busy_first'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_stale_busy_first'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_stale_busy_first'
			target:      'chat_codexbot_ts_stale_busy'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('first task goes stale', 'chat_codexbot_ts_stale_busy',
				'om_codexbot_stale_busy_first')
		}) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'
		time.sleep(5 * time.millisecond)

		second_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_stale_busy_second'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_stale_busy_second'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_stale_busy_second'
			target:      'chat_codexbot_ts_stale_busy'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('second task should proceed', 'chat_codexbot_ts_stale_busy',
				'om_codexbot_stale_busy_second')
		}) or { panic(err) }
		assert second_resp.handled
		assert second_resp.commands.len == 1
		assert second_resp.commands[0].type_ == 'provider.rpc.call'

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_stale_busy_state'
			request_id:  'req_codexbot_ts_stale_busy_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"lastEvent":"stale.auto_detach"')
		assert state_resp.response.body.contains('second task should proceed')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_busy_guard_stays_within_same_feishu_thread() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_busy_guard.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_thread_busy_first'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_busy_first'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_busy_first'
			target:      'chat_codexbot_ts_thread_busy'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_thread_payload('thread busy first', 'chat_codexbot_ts_thread_busy',
				'om_codexbot_thread_busy_first', 'om_thread_busy_root', 'om_thread_busy_parent')
		}) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'

		second_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_busy_second'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_busy_second'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_busy_second'
			target:      'chat_codexbot_ts_thread_busy'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_thread_payload('thread busy second', 'chat_codexbot_ts_thread_busy',
				'om_codexbot_thread_busy_second', 'om_thread_busy_root', 'om_thread_busy_parent_2')
		}) or { panic(err) }
		assert second_resp.handled
		assert second_resp.commands.len == 1
		assert second_resp.commands[0].type_ == 'provider.message.send'
		assert second_resp.commands[0].target_type == 'message_id'
		assert second_resp.commands[0].target == 'om_codexbot_thread_busy_second'
		assert second_resp.commands[0].text.contains('Still working on the previous request in this thread.')
	})
}
