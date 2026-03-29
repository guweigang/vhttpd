module main

import net.http
import os
import json
import time

fn codexbot_ts_feishu_payload(text string, chat_id string, message_id string) string {
	content_json := json.encode({
		'text': text
	})
	return '{"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","content":${json.encode(content_json)}}}}'
}

fn codexbot_ts_feishu_thread_payload(text string, chat_id string, message_id string, root_id string, parent_id string) string {
	content_json := json.encode({
		'text': text
	})
	return '{"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","root_id":"${root_id}","parent_id":"${parent_id}","content":${json.encode(content_json)}}}}'
}

fn codexbot_ts_with_temp_db(db_name string, run fn (string)) {
	with_temp_sqlite_db_env('CODEXBOT_TS_DB_PATH', db_name, run)
}

fn codexbot_ts_app_file() string {
	return os.real_path(os.join_path(os.dir(@FILE), '..', 'examples', 'codexbot-app-ts', 'app.mts'))
}

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
		assert task_resp.commands.len == 2
		assert task_resp.commands[0].type_ == 'provider.message.send'
		assert task_resp.commands[0].provider == 'feishu'
		assert task_resp.commands[0].stream_id.starts_with('codex:ts_')
		assert task_resp.commands[1].type_ == 'provider.rpc.call'
		assert task_resp.commands[1].provider == 'codex'
		assert task_resp.commands[1].method == 'thread/start'
		assert task_resp.commands[1].stream_id == task_resp.commands[0].stream_id
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
		stream_id := task_resp.commands[0].stream_id
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
		assert rpc_resp.commands.len == 2
		assert rpc_resp.commands[0].type_ == 'provider.message.update'
		assert rpc_resp.commands[0].stream_id == stream_id
		assert rpc_resp.commands[0].message_type == 'interactive'
		assert rpc_resp.commands[0].content.contains('thread_ts_001')
		assert rpc_resp.commands[1].type_ == 'provider.rpc.call'
		assert rpc_resp.commands[1].method == 'turn/start'
		assert rpc_resp.commands[1].stream_id == stream_id

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
		assert turn_resp.commands.len == 1
		assert turn_resp.commands[0].type_ == 'provider.message.update'
		assert turn_resp.commands[0].content.contains('**Running**')

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
		assert notif_resp.commands.len == 1
		assert notif_resp.commands[0].type_ == 'provider.message.update'
		assert notif_resp.commands[0].stream_id == stream_id
		assert notif_resp.commands[0].message_type == 'interactive'
		assert notif_resp.commands[0].content.contains('hello from codex')
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
		stream_id := task_resp.commands[0].stream_id
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
		assert notif_resp.commands.len == 2
		assert notif_resp.commands[0].type_ == 'provider.message.update'
		assert notif_resp.commands[0].content.contains('thread_ts_003')
		assert notif_resp.commands[1].type_ == 'provider.rpc.call'
		assert notif_resp.commands[1].method == 'turn/start'
		assert notif_resp.commands[1].params.contains('"threadId":"thread_ts_003"')

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
		stream_id := task_resp.commands[0].stream_id
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
		assert first_resp.commands.len == 2
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
		assert first_resp.commands.len == 2
		assert first_resp.commands[0].type_ == 'provider.message.send'
		assert first_resp.commands[0].target_type == 'message_id'
		assert first_resp.commands[0].target == 'om_codexbot_thread_scope_first'

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
		assert second_resp.commands.len == 2
		assert second_resp.commands[0].type_ == 'provider.message.send'
		assert second_resp.commands[0].target_type == 'message_id'
		assert second_resp.commands[0].target == 'om_codexbot_thread_scope_second'
		assert second_resp.commands[0].text.contains('**Queued**')

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
		assert first_resp.commands.len == 2

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

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_command_reports_thread_scoped_session() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_scope_command.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_thread_scope_cmd_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_scope_cmd_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_scope_cmd_task'
			target:      'chat_codexbot_ts_thread_scope_cmd'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_thread_payload('thread scoped task', 'chat_codexbot_ts_thread_scope_cmd',
				'om_codexbot_thread_scope_cmd_task', 'om_thread_scope_cmd_root', 'om_thread_scope_cmd_parent')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_scope_cmd_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_scope_cmd_001"},"has_error":false}'
		}) or { panic(err) }

		thread_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_scope_cmd_query'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_scope_cmd_query'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_scope_cmd_query'
			target:      'chat_codexbot_ts_thread_scope_cmd'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_thread_payload('/thread', 'chat_codexbot_ts_thread_scope_cmd',
				'om_codexbot_thread_scope_cmd_query', 'om_thread_scope_cmd_root', 'om_thread_scope_cmd_parent_2')
		}) or { panic(err) }
		assert thread_resp.handled
		assert thread_resp.commands.len == 1
		assert thread_resp.commands[0].type_ == 'provider.message.send'
		assert thread_resp.commands[0].target_type == 'message_id'
		assert thread_resp.commands[0].target == 'om_codexbot_thread_scope_cmd_query'
		assert thread_resp.commands[0].text.contains('Session Scope: current Feishu thread')
		assert thread_resp.commands[0].text.contains('Current thread: `thread_scope_cmd_001`')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_threads_command_lists_recent_project_threads() {
	codexbot_ts_with_temp_db('codexbot_ts_threads_list.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_threads_list_task_1'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_threads_list_task_1'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_threads_list_task_1'
			target:      'chat_codexbot_ts_threads_list'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('inspect bug one', 'chat_codexbot_ts_threads_list',
				'om_codexbot_threads_list_task_1')
		}) or { panic(err) }
		first_stream_id := first_task.commands[0].stream_id
		assert first_stream_id != ''
		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_threads_list_rpc_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_list_001"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_threads_list_done_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{}}'
		}) or { panic(err) }

		second_task := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_threads_list_task_2'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_threads_list_task_2'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_threads_list_task_2'
			target:      'chat_codexbot_ts_threads_list'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/new', 'chat_codexbot_ts_threads_list',
				'om_codexbot_threads_list_task_2')
		}) or { panic(err) }
		assert second_task.commands.len == 1

		third_task := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_threads_list_task_3'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_threads_list_task_3'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_threads_list_task_3'
			target:      'chat_codexbot_ts_threads_list'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('inspect bug two', 'chat_codexbot_ts_threads_list',
				'om_codexbot_threads_list_task_3')
		}) or { panic(err) }
		second_stream_id := third_task.commands[0].stream_id
		assert second_stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_threads_list_rpc_2'
			provider:   'codex'
			instance:   'main'
			trace_id:   second_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_list_002"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_threads_list_done_2'
			provider:   'codex'
			instance:   'main'
			trace_id:   second_stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{}}'
		}) or { panic(err) }

		threads_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_threads_list_query'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_threads_list_query'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_threads_list_query'
			target:      'chat_codexbot_ts_threads_list'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/threads', 'chat_codexbot_ts_threads_list',
				'om_codexbot_threads_list_query')
		}) or { panic(err) }
		assert threads_resp.handled
		assert threads_resp.commands.len == 1
		assert threads_resp.commands[0].text.contains('**Recent Threads**')
		assert threads_resp.commands[0].text.contains('thread_list_001')
		assert threads_resp.commands[0].text.contains('thread_list_002')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_use_latest_and_thread_switch_reuse_selected_thread() {
	codexbot_ts_with_temp_db('codexbot_ts_use_latest.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_use_latest_task_1'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_use_latest_task_1'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_use_latest_task_1'
			target:      'chat_codexbot_ts_use_latest'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('first thread seed', 'chat_codexbot_ts_use_latest',
				'om_codexbot_use_latest_task_1')
		}) or { panic(err) }
		first_stream_id := first_task.commands[0].stream_id
		assert first_stream_id != ''
		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_use_latest_rpc_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_use_latest_001"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_use_latest_done_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{}}'
		}) or { panic(err) }

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_use_latest_new'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_use_latest_new'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_use_latest_new'
			target:      'chat_codexbot_ts_use_latest'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/new', 'chat_codexbot_ts_use_latest',
				'om_codexbot_use_latest_new')
		}) or { panic(err) }

		use_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_use_latest_cmd'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_use_latest_cmd'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_use_latest_cmd'
			target:      'chat_codexbot_ts_use_latest'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/use latest', 'chat_codexbot_ts_use_latest',
				'om_codexbot_use_latest_cmd')
		}) or { panic(err) }
		assert use_resp.handled
		assert use_resp.commands.len == 2
		assert use_resp.commands[0].text.contains('thread_use_latest_001')
		assert use_resp.commands[0].text.contains('Reading the latest assistant reply from this thread.')
		assert use_resp.commands[1].type_ == 'provider.rpc.call'
		assert use_resp.commands[1].method == 'thread/read'
		assert use_resp.commands[1].params.contains('"threadId":"thread_use_latest_001"')
		assert use_resp.commands[1].params.contains('"includeTurns":true')
		use_stream_id := use_resp.commands[0].stream_id
		assert use_stream_id != ''

		read_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_use_latest_read_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   use_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_use_latest_001","turns":[{"items":[{"type":"message","role":"assistant","content":[{"text":"hello from latest thread"}]}]}]}},"has_error":false}'
		}) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 1
		assert read_resp.commands[0].type_ == 'provider.message.update'
		assert read_resp.commands[0].content.contains('hello from latest thread')

		second_task := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_use_latest_task_2'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_use_latest_task_2'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_use_latest_task_2'
			target:      'chat_codexbot_ts_use_latest'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('continue latest', 'chat_codexbot_ts_use_latest',
				'om_codexbot_use_latest_task_2')
		}) or { panic(err) }
		assert second_task.handled
		assert second_task.commands.len == 2
		assert second_task.commands[1].method == 'turn/start'
		assert second_task.commands[1].params.contains('"threadId":"thread_use_latest_001"')

		thread_switch_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_switch_cmd'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_switch_cmd'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_switch_cmd'
			target:      'chat_codexbot_ts_use_latest'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/thread thread_use_latest_001', 'chat_codexbot_ts_use_latest',
				'om_codexbot_thread_switch_cmd')
		}) or { panic(err) }
		assert thread_switch_resp.handled
		assert thread_switch_resp.commands.len == 1
		assert thread_switch_resp.commands[0].text.contains('**Thread Selected**')
		assert thread_switch_resp.commands[0].text.contains('Thread: `thread_use_latest_001`')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_rename_command() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_rename.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_thread_rename_seed'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_rename_seed'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_rename_seed'
			target:      'chat_codexbot_ts_thread_rename'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('seed thread for rename', 'chat_codexbot_ts_thread_rename',
				'om_codexbot_thread_rename_seed')
		}) or { panic(err) }
		first_stream_id := first_task.commands[0].stream_id
		assert first_stream_id != ''
		_ := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_rename_seed_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_rename_001"},"has_error":false}'
		}) or { panic(err) }

		rename_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_rename_cmd'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_rename_cmd'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_rename_cmd'
			target:      'chat_codexbot_ts_thread_rename'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/thread rename Stable Name',
				'chat_codexbot_ts_thread_rename', 'om_codexbot_thread_rename_cmd')
		}) or { panic(err) }
		assert rename_resp.handled
		assert rename_resp.commands.len == 2
		assert rename_resp.commands[0].text.contains('**Thread Rename**')
		assert rename_resp.commands[0].text.contains('Stable Name')
		assert rename_resp.commands[1].type_ == 'provider.rpc.call'
		assert rename_resp.commands[1].method == 'thread/name/set'
		assert rename_resp.commands[1].params.contains('"threadId":"thread_rename_001"')
		assert rename_resp.commands[1].params.contains('"name":"Stable Name"')
		rename_stream_id := rename_resp.commands[0].stream_id
		assert rename_stream_id != ''

		thread_resp_pending := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_rename_thread_view_pending'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_rename_thread_view_pending'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_rename_thread_view_pending'
			target:      'chat_codexbot_ts_thread_rename'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/thread', 'chat_codexbot_ts_thread_rename',
				'om_codexbot_thread_rename_thread_view_pending')
		}) or { panic(err) }
		assert thread_resp_pending.handled
		assert thread_resp_pending.commands.len == 1
		assert thread_resp_pending.commands[0].text.contains('Stable Name')

		rename_done := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_rename_done'
			provider:   'codex'
			instance:   'main'
			trace_id:   rename_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/name/set","result":{"thread":{"id":"thread_rename_001","name":"Stable Name"}},"has_error":false}'
		}) or { panic(err) }
		assert rename_done.handled
		assert rename_done.commands.len == 1
		assert rename_done.commands[0].type_ == 'provider.message.update'
		assert rename_done.commands[0].content.contains('**Thread Renamed**')
		assert rename_done.commands[0].content.contains('Stable Name')

		thread_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_rename_thread_view'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_rename_thread_view'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_rename_thread_view'
			target:      'chat_codexbot_ts_thread_rename'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/thread', 'chat_codexbot_ts_thread_rename',
				'om_codexbot_thread_rename_thread_view')
		}) or { panic(err) }
		assert thread_resp.handled
		assert thread_resp.commands.len == 1
		assert thread_resp.commands[0].text.contains('Stable Name')

		threads_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_rename_threads_view'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_rename_threads_view'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_thread_rename_threads_view'
			target:      'chat_codexbot_ts_thread_rename'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/threads', 'chat_codexbot_ts_thread_rename',
				'om_codexbot_thread_rename_threads_view')
		}) or { panic(err) }
		assert threads_resp.handled
		assert threads_resp.commands.len == 1
		assert threads_resp.commands[0].text.contains('Stable Name')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_projects_and_models_commands_use_selection_scope() {
	codexbot_ts_with_temp_db('codexbot_ts_projects_models.sqlite', fn (_ string) {
		suffix := '${time.now().unix_milli()}'
		project_root := os.join_path(os.temp_dir(), 'codexbot_ts_projects_models_root_' + suffix)
		os.mkdir_all(project_root) or { panic(err) }
		os.mkdir_all(os.join_path(project_root, 'beta')) or { panic(err) }
		defer {
			os.rmdir_all(project_root) or {}
		}

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

		setting_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_projects_models_setting'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_projects_models_setting'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_projects_models_setting'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/setting project_root_dir ' + project_root,
				'chat_codexbot_ts_projects_models', 'om_codexbot_ts_projects_models_setting')
		}) or { panic(err) }
		assert setting_resp.handled
		assert setting_resp.commands.len == 1
		assert setting_resp.commands[0].text.contains('**Setting Updated**')

		create_alpha := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_projects_models_create_alpha'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_projects_models_create_alpha'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_projects_models_create_alpha'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/create alpha', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_projects_models_create_alpha')
		}) or { panic(err) }
		assert create_alpha.handled
		assert create_alpha.commands.len == 1
		assert create_alpha.commands[0].text.contains('**Project Created**')
		assert create_alpha.commands[0].text.contains('Project: `alpha`')

		bind_beta := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_projects_models_bind_beta'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_projects_models_bind_beta'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_projects_models_bind_beta'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/bind beta', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_projects_models_bind_beta')
		}) or { panic(err) }
		assert bind_beta.handled
		assert bind_beta.commands.len == 1
		assert bind_beta.commands[0].text.contains('Project: `beta`')

		alpha_task := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_alpha_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_alpha_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_alpha_task'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('alpha task', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_alpha_task')
		}) or { panic(err) }
		alpha_stream_id := alpha_task.commands[0].stream_id
		assert alpha_stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_alpha_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   alpha_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_project_alpha"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_alpha_done'
			provider:   'codex'
			instance:   'main'
			trace_id:   alpha_stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{}}'
		}) or { panic(err) }

		switch_beta := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_switch_beta'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_switch_beta'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_switch_beta'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/project beta', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_switch_beta')
		}) or { panic(err) }
		assert switch_beta.commands[0].text.contains('Project: `beta`')

		beta_task := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_beta_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_beta_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_beta_task'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('beta task', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_beta_task')
		}) or { panic(err) }
		beta_stream_id := beta_task.commands[0].stream_id
		assert beta_stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_beta_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   beta_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_project_beta"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_beta_done'
			provider:   'codex'
			instance:   'main'
			trace_id:   beta_stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{}}'
		}) or { panic(err) }

		projects_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_projects_list'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_projects_list'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_projects_list'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/projects', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_projects_list')
		}) or { panic(err) }
		assert projects_resp.handled
		assert projects_resp.commands.len == 1
		assert projects_resp.commands[0].text.contains('**Projects**')
		assert projects_resp.commands[0].text.contains('Chat: `chat_codexbot_ts_projects_models`')
		assert projects_resp.commands[0].text.contains('alpha')
		assert projects_resp.commands[0].text.contains('`beta` current')

		use_project_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_projects_use_alpha'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_projects_use_alpha'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_projects_use_alpha'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/use alpha', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_projects_use_alpha')
		}) or { panic(err) }
		assert use_project_resp.handled
		assert use_project_resp.commands.len == 1
		assert use_project_resp.commands[0].text.contains('Project: `alpha`')

		use_project_resp_2 := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_projects_use_beta_again'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_projects_use_beta_again'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_projects_use_beta_again'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/use beta', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_projects_use_beta_again')
		}) or { panic(err) }
		assert use_project_resp_2.handled
		assert use_project_resp_2.commands.len == 1
		assert use_project_resp_2.commands[0].text.contains('Project: `beta`')

		models_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_models_list'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_models_list'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_models_list'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/models', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_models_list')
		}) or { panic(err) }
		assert models_resp.handled
		assert models_resp.commands.len == 1
		assert models_resp.commands[0].text.contains('**Configured Models**')
		assert models_resp.commands[0].text.contains('`gpt-5.4` current')
		assert models_resp.commands[0].text.contains('gpt-5.3-codex')

		use_model_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_models_use'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_models_use'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_models_use'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/use gpt-5.3-codex', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_models_use')
		}) or { panic(err) }
		assert use_model_resp.handled
		assert use_model_resp.commands.len == 1
		assert use_model_resp.commands[0].text.contains('**Model Updated**')
		assert use_model_resp.commands[0].text.contains('`gpt-5.3-codex`')

		use_model_resp_2 := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_models_use_default_again'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_models_use_default_again'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_models_use_default_again'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/use gpt-5.4', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_models_use_default_again')
		}) or { panic(err) }
		assert use_model_resp_2.handled
		assert use_model_resp_2.commands.len == 1
		assert use_model_resp_2.commands[0].text.contains('**Model Updated**')
		assert use_model_resp_2.commands[0].text.contains('`gpt-5.4`')

		current_project_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_projects_scope_clear'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_projects_scope_clear'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_projects_scope_clear'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/project', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_projects_scope_clear')
		}) or { panic(err) }
		assert current_project_resp.handled
		assert current_project_resp.commands.len == 1
		assert current_project_resp.commands[0].text.contains('**Current Project**')

		use_after_scope_cleared := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_projects_use_after_scope_cleared'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_projects_use_after_scope_cleared'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_projects_use_after_scope_cleared'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/use alpha', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_projects_use_after_scope_cleared')
		}) or { panic(err) }
		assert use_after_scope_cleared.handled
		assert use_after_scope_cleared.commands.len == 2
		assert use_after_scope_cleared.commands[0].text.contains('**Thread Selected**')
		assert use_after_scope_cleared.commands[0].text.contains('Thread: `alpha`')
		assert use_after_scope_cleared.commands[1].method == 'thread/read'
		assert use_after_scope_cleared.commands[1].params.contains('"threadId":"alpha"')

		next_task := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_model_applied_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_model_applied_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_model_applied_task'
			target:      'chat_codexbot_ts_projects_models'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('task after model switch', 'chat_codexbot_ts_projects_models',
				'om_codexbot_ts_model_applied_task')
		}) or { panic(err) }
		assert next_task.handled
		assert next_task.commands.len == 2
		assert next_task.commands[1].method == 'turn/start'
		assert next_task.commands[1].params.contains('"model":"gpt-5.4"')
		assert next_task.commands[1].params.contains('"threadId":"alpha"')
		assert next_task.commands[1].params.contains('/beta')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_new_command_can_switch_model_and_clear_thread() {
	codexbot_ts_with_temp_db('codexbot_ts_new_model.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_new_model_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_new_model_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_new_model_task'
			target:      'chat_codexbot_ts_new_model'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('seed thread', 'chat_codexbot_ts_new_model',
				'om_codexbot_ts_new_model_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_new_model_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_new_model_001"},"has_error":false}'
		}) or { panic(err) }

		reset_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_new_model_reset'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_new_model_reset'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_new_model_reset'
			target:      'chat_codexbot_ts_new_model'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/new gpt-5.3-codex', 'chat_codexbot_ts_new_model',
				'om_codexbot_ts_new_model_reset')
		}) or { panic(err) }
		assert reset_resp.handled
		assert reset_resp.commands.len == 1
		assert reset_resp.commands[0].text.contains('**New Conversation**')
		assert reset_resp.commands[0].text.contains('Previous Thread: `thread_new_model_001`')
		assert reset_resp.commands[0].text.contains('Model switched: `gpt-5.4` -> `gpt-5.3-codex`')

		thread_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_new_model_thread'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_new_model_thread'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_new_model_thread'
			target:      'chat_codexbot_ts_new_model'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/thread', 'chat_codexbot_ts_new_model',
				'om_codexbot_ts_new_model_thread')
		}) or { panic(err) }
		assert thread_resp.handled
		assert thread_resp.commands.len == 1
		assert thread_resp.commands[0].text.contains('No thread is currently bound.')

		model_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_new_model_model'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_new_model_model'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_new_model_model'
			target:      'chat_codexbot_ts_new_model'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/model', 'chat_codexbot_ts_new_model',
				'om_codexbot_ts_new_model_model')
		}) or { panic(err) }
		assert model_resp.handled
		assert model_resp.commands.len == 1
		assert model_resp.commands[0].text.contains('**Current Model**')
		assert model_resp.commands[0].text.contains('`gpt-5.3-codex`')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_create_import_and_bind_projects() {
	codexbot_ts_with_temp_db('codexbot_ts_project_registry.sqlite', fn (_ string) {
		suffix := '${time.now().unix_milli()}'
		project_root := os.join_path(os.temp_dir(), 'codexbot_ts_project_root_' + suffix)
		import_root := os.join_path(os.temp_dir(), 'codexbot_ts_imported_repo_' + suffix)
		os.mkdir_all(project_root) or { panic(err) }
		os.mkdir_all(import_root) or { panic(err) }
		defer {
			os.rmdir_all(project_root) or {}
			os.rmdir_all(import_root) or {}
		}

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

		setting_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_setting_project_root'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_setting_project_root'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_setting_project_root'
			target:      'chat_codexbot_ts_project_registry'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/setting project_root_dir ' + project_root,
				'chat_codexbot_ts_project_registry', 'om_codexbot_ts_setting_project_root')
		}) or { panic(err) }
		assert setting_resp.handled
		assert setting_resp.commands.len == 1
		assert setting_resp.commands[0].text.contains('**Setting Updated**')
		assert setting_resp.commands[0].text.contains('`project_root_dir` = `' + project_root + '`')

		create_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_create_project'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_create_project'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_create_project'
			target:      'chat_codexbot_ts_project_registry'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/create alpha', 'chat_codexbot_ts_project_registry',
				'om_codexbot_ts_create_project')
		}) or { panic(err) }
		assert create_resp.handled
		assert create_resp.commands.len == 1
		assert create_resp.commands[0].text.contains('**Project Created**')
		assert create_resp.commands[0].text.contains('Project: `alpha`')
		assert create_resp.commands[0].text.contains(os.join_path(project_root, 'alpha'))
		assert os.is_dir(os.join_path(project_root, 'alpha'))

		import_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_import_project'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_import_project'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_import_project'
			target:      'chat_codexbot_ts_project_registry'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/import beta ' + import_root, 'chat_codexbot_ts_project_registry',
				'om_codexbot_ts_import_project')
		}) or { panic(err) }
		assert import_resp.handled
		assert import_resp.commands.len == 1
		assert import_resp.commands[0].text.contains('**Command Updated**')
		assert import_resp.commands[0].text.contains('/import')
		assert import_resp.commands[0].text.contains('/bind [project_key] [path]')

		bind_import_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_bind_import_project'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_bind_import_project'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_bind_import_project'
			target:      'chat_codexbot_ts_project_registry'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/bind beta ' + import_root, 'chat_codexbot_ts_project_registry',
				'om_codexbot_ts_bind_import_project')
		}) or { panic(err) }
		assert bind_import_resp.handled
		assert bind_import_resp.commands.len == 1
		assert bind_import_resp.commands[0].text.contains('Project: `beta`')
		assert bind_import_resp.commands[0].text.contains(import_root)

		switch_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_switch_to_alpha'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_switch_to_alpha'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_switch_to_alpha'
			target:      'chat_codexbot_ts_project_registry'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/project alpha', 'chat_codexbot_ts_project_registry',
				'om_codexbot_ts_switch_to_alpha')
		}) or { panic(err) }
		assert switch_resp.handled
		assert switch_resp.commands.len == 1
		assert switch_resp.commands[0].text.contains('Project: `alpha`')

		bind_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_bind_beta'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_bind_beta'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_bind_beta'
			target:      'chat_codexbot_ts_project_registry'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/bind beta', 'chat_codexbot_ts_project_registry',
				'om_codexbot_ts_bind_beta')
		}) or { panic(err) }
		assert bind_resp.handled
		assert bind_resp.commands.len == 1
		assert bind_resp.commands[0].text.contains('**Import Path Invalid**')
		assert bind_resp.commands[0].text.contains(os.join_path(project_root, 'beta'))

		current_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_project_current'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_project_current'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_project_current'
			target:      'chat_codexbot_ts_project_registry'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/project', 'chat_codexbot_ts_project_registry',
				'om_codexbot_ts_project_current')
		}) or { panic(err) }
		assert current_resp.handled
		assert current_resp.commands.len == 1
		assert current_resp.commands[0].text.contains('**Current Project**')
		assert current_resp.commands[0].text.contains('Project: `alpha`')

		projects_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_project_list'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_project_list'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_project_list'
			target:      'chat_codexbot_ts_project_registry'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/projects', 'chat_codexbot_ts_project_registry',
				'om_codexbot_ts_project_list')
		}) or { panic(err) }
		assert projects_resp.handled
		assert projects_resp.commands.len == 1
		assert projects_resp.commands[0].text.contains('`alpha` current')
		assert projects_resp.commands[0].text.contains('beta')

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_project_registry_state'
			request_id:  'req_codexbot_ts_project_registry_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"projectKey":"alpha"')
		assert state_resp.response.body.contains('"projectKey":"beta"')
		assert state_resp.response.body.contains('"bindings"')
		assert state_resp.response.body.contains('"settings"')
		assert state_resp.response.body.contains('"name":"project_root_dir"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_unbind_blocks_current_project_and_removes_non_current_binding() {
	codexbot_ts_with_temp_db('codexbot_ts_unbind.sqlite', fn (_ string) {
		suffix := '${time.now().unix_milli()}'
		project_root := os.join_path(os.temp_dir(), 'codexbot_ts_unbind_root_' + suffix)
		os.mkdir_all(project_root) or { panic(err) }
		defer {
			os.rmdir_all(project_root) or {}
		}
		os.mkdir_all(os.join_path(project_root, 'beta')) or { panic(err) }

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

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_unbind_setting_project_root'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_unbind_setting_project_root'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_unbind_setting_project_root'
			target:      'chat_codexbot_ts_unbind'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/setting project_root_dir ' + project_root,
				'chat_codexbot_ts_unbind', 'om_codexbot_ts_unbind_setting_project_root')
		}) or { panic(err) }

		create_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_unbind_create_alpha'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_unbind_create_alpha'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_unbind_create_alpha'
			target:      'chat_codexbot_ts_unbind'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/create alpha', 'chat_codexbot_ts_unbind',
				'om_codexbot_ts_unbind_create_alpha')
		}) or { panic(err) }
		assert create_resp.handled
		assert create_resp.commands[0].text.contains('Project: `alpha`')

		bind_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_unbind_bind_beta'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_unbind_bind_beta'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_unbind_bind_beta'
			target:      'chat_codexbot_ts_unbind'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/bind beta', 'chat_codexbot_ts_unbind',
				'om_codexbot_ts_unbind_bind_beta')
		}) or { panic(err) }
		assert bind_resp.handled
		assert bind_resp.commands[0].text.contains('Project: `beta`')

		blocked_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_unbind_alpha_blocked'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_unbind_alpha_blocked'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_unbind_alpha_blocked'
			target:      'chat_codexbot_ts_unbind'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/unbind alpha', 'chat_codexbot_ts_unbind',
				'om_codexbot_ts_unbind_alpha_blocked')
		}) or { panic(err) }
		assert blocked_resp.handled
		assert blocked_resp.commands.len == 1
		assert blocked_resp.commands[0].text.contains('**Cannot Unbind Current Project**')
		assert blocked_resp.commands[0].text.contains('Project: `alpha`')

		unbind_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_unbind_beta'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_unbind_beta'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_unbind_beta'
			target:      'chat_codexbot_ts_unbind'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/unbind beta', 'chat_codexbot_ts_unbind',
				'om_codexbot_ts_unbind_beta')
		}) or { panic(err) }
		assert unbind_resp.handled
		assert unbind_resp.commands.len == 1
		assert unbind_resp.commands[0].text.contains('**Project Unbound**')
		assert unbind_resp.commands[0].text.contains('Project: `beta`')

		projects_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_unbind_projects'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_unbind_projects'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_unbind_projects'
			target:      'chat_codexbot_ts_unbind'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/projects', 'chat_codexbot_ts_unbind',
				'om_codexbot_ts_unbind_projects')
		}) or { panic(err) }
		assert projects_resp.handled
		assert projects_resp.commands.len == 1
		assert projects_resp.commands[0].text.contains('`alpha` current')
		assert !projects_resp.commands[0].text.contains('`beta`')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_projects_self_heal_legacy_binding_state() {
	codexbot_ts_with_temp_db('codexbot_ts_legacy_project_bindings.sqlite', fn (_ string) {
		suffix := '${time.now().unix_milli()}'
		project_root := os.join_path(os.temp_dir(), 'codexbot_ts_legacy_bindings_root_' + suffix)
		mutator_dir := os.join_path(os.temp_dir(), 'codexbot_ts_legacy_bindings_mutator_' + suffix)
		os.mkdir_all(project_root) or { panic(err) }
		os.mkdir_all(mutator_dir) or { panic(err) }
		defer {
			os.rmdir_all(project_root) or {}
			os.rmdir_all(mutator_dir) or {}
		}

		mutator_file := os.join_path(mutator_dir, 'mutator.mts')
		mutator_source := 'import { open } from "sqlite";\n' + '\n' +
			'globalThis.__vhttpd_handle = async (ctx) => {\n' +
			'  const dbPath = process.env.CODEXBOT_TS_DB_PATH;\n' +
			'  const db = await open({ path: dbPath, busyTimeout: 5000 });\n' +
			'  await db.exec("delete from project_binding_state where chat_id = \'chat_codexbot_ts_legacy_projects\'");\n' +
			'  await db.exec("delete from project_registry where project_key = \'alpha\'");\n' +
			'  await db.close();\n' + '  return ctx.json({ ok: true, dbPath });\n' + '};\n'
		os.write_file(mutator_file, mutator_source) or { panic(err) }

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
		mut mutator := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       mutator_file
			module_root:     mutator_dir
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			mutator.close()
		}
		mut app := App{}

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_legacy_bindings_setting_project_root'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_legacy_bindings_setting_project_root'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_legacy_bindings_setting_project_root'
			target:      'chat_codexbot_ts_legacy_projects'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/setting project_root_dir ' + project_root,
				'chat_codexbot_ts_legacy_projects', 'om_codexbot_ts_legacy_bindings_setting_project_root')
		}) or { panic(err) }

		create_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_legacy_bindings_create_alpha'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_legacy_bindings_create_alpha'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_legacy_bindings_create_alpha'
			target:      'chat_codexbot_ts_legacy_projects'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/create alpha', 'chat_codexbot_ts_legacy_projects',
				'om_codexbot_ts_legacy_bindings_create_alpha')
		}) or { panic(err) }
		assert create_resp.handled
		assert create_resp.commands.len == 1
		assert create_resp.commands[0].text.contains('Project: `alpha`')

		mutator_resp := mutator.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'POST'
			path:        '/mutate'
			req:         http.Request{
				method: .post
				url:    '/mutate'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_legacy_bindings_mutator'
			request_id:  'req_codexbot_ts_legacy_bindings_mutator'
		}) or { panic(err) }
		assert mutator_resp.response.status == 200
		assert mutator_resp.response.body.contains('"ok":true')

		current_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_legacy_bindings_project_current'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_legacy_bindings_project_current'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_legacy_bindings_project_current'
			target:      'chat_codexbot_ts_legacy_projects'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/project', 'chat_codexbot_ts_legacy_projects',
				'om_codexbot_ts_legacy_bindings_project_current')
		}) or { panic(err) }
		assert current_resp.handled
		assert current_resp.commands.len == 1
		assert current_resp.commands[0].text.contains('Project: `alpha`')

		projects_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_legacy_bindings_projects'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_legacy_bindings_projects'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_legacy_bindings_projects'
			target:      'chat_codexbot_ts_legacy_projects'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/projects', 'chat_codexbot_ts_legacy_projects',
				'om_codexbot_ts_legacy_bindings_projects')
		}) or { panic(err) }
		assert projects_resp.handled
		assert projects_resp.commands.len == 1
		assert projects_resp.commands[0].text.contains('**Projects**')
		assert projects_resp.commands[0].text.contains('`alpha` current')
		assert !projects_resp.commands[0].text.contains('No bound projects yet')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_create_and_bind_failure_paths() {
	codexbot_ts_with_temp_db('codexbot_ts_create_bind_failures.sqlite', fn (_ string) {
		suffix := '${time.now().unix_milli()}'
		project_root := os.join_path(os.temp_dir(), 'codexbot_ts_create_bind_failures_root_' +
			suffix)
		explicit_bind_root := os.join_path(os.temp_dir(),
			'codexbot_ts_create_bind_failures_bind_' + suffix)
		missing_bind_root := os.join_path(os.temp_dir(),
			'codexbot_ts_create_bind_failures_missing_' + suffix)
		os.mkdir_all(project_root) or { panic(err) }
		os.mkdir_all(explicit_bind_root) or { panic(err) }
		os.mkdir_all(os.join_path(project_root, 'gamma')) or { panic(err) }
		defer {
			os.rmdir_all(project_root) or {}
			os.rmdir_all(explicit_bind_root) or {}
			os.rmdir_all(missing_bind_root) or {}
		}

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

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_create_bind_failures_setting'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_create_bind_failures_setting'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_create_bind_failures_setting'
			target:      'chat_codexbot_ts_create_bind_failures'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/setting project_root_dir ' + project_root,
				'chat_codexbot_ts_create_bind_failures', 'om_codexbot_ts_create_bind_failures_setting')
		}) or { panic(err) }

		create_alpha := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_create_bind_failures_create_alpha'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_create_bind_failures_create_alpha'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_create_bind_failures_create_alpha'
			target:      'chat_codexbot_ts_create_bind_failures'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/create alpha', 'chat_codexbot_ts_create_bind_failures',
				'om_codexbot_ts_create_bind_failures_create_alpha')
		}) or { panic(err) }
		assert create_alpha.handled
		assert create_alpha.commands[0].text.contains('**Project Created**')

		create_alpha_again := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_create_bind_failures_create_alpha_again'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_create_bind_failures_create_alpha_again'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_create_bind_failures_create_alpha_again'
			target:      'chat_codexbot_ts_create_bind_failures'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/create alpha', 'chat_codexbot_ts_create_bind_failures',
				'om_codexbot_ts_create_bind_failures_create_alpha_again')
		}) or { panic(err) }
		assert create_alpha_again.handled
		assert create_alpha_again.commands.len == 1
		assert create_alpha_again.commands[0].text.contains('**Project Exists**')
		assert create_alpha_again.commands[0].text.contains('Project: `alpha`')
		assert create_alpha_again.commands[0].text.contains(os.join_path(project_root,
			'alpha'))

		create_gamma := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_create_bind_failures_create_gamma'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_create_bind_failures_create_gamma'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_create_bind_failures_create_gamma'
			target:      'chat_codexbot_ts_create_bind_failures'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/create gamma', 'chat_codexbot_ts_create_bind_failures',
				'om_codexbot_ts_create_bind_failures_create_gamma')
		}) or { panic(err) }
		assert create_gamma.handled
		assert create_gamma.commands.len == 1
		assert create_gamma.commands[0].text.contains('**Project Directory Exists**')
		assert create_gamma.commands[0].text.contains('Project: `gamma`')
		assert create_gamma.commands[0].text.contains(os.join_path(project_root, 'gamma'))

		bind_beta := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_create_bind_failures_bind_beta'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_create_bind_failures_bind_beta'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_create_bind_failures_bind_beta'
			target:      'chat_codexbot_ts_create_bind_failures'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/bind beta ' + explicit_bind_root,
				'chat_codexbot_ts_create_bind_failures', 'om_codexbot_ts_create_bind_failures_bind_beta')
		}) or { panic(err) }
		assert bind_beta.handled
		assert bind_beta.commands.len == 1
		assert bind_beta.commands[0].text.contains('Project: `beta`')
		assert bind_beta.commands[0].text.contains(explicit_bind_root)

		bind_beta_again := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_create_bind_failures_bind_beta_again'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_create_bind_failures_bind_beta_again'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_create_bind_failures_bind_beta_again'
			target:      'chat_codexbot_ts_create_bind_failures'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/bind beta ' + explicit_bind_root,
				'chat_codexbot_ts_create_bind_failures', 'om_codexbot_ts_create_bind_failures_bind_beta_again')
		}) or { panic(err) }
		assert bind_beta_again.handled
		assert bind_beta_again.commands.len == 1
		assert bind_beta_again.commands[0].text.contains('**Project Path Already Bound**')
		assert bind_beta_again.commands[0].text.contains('Project: `beta`')
		assert bind_beta_again.commands[0].text.contains(explicit_bind_root)

		bind_missing := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_create_bind_failures_bind_missing'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_create_bind_failures_bind_missing'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_create_bind_failures_bind_missing'
			target:      'chat_codexbot_ts_create_bind_failures'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/bind delta ' + missing_bind_root,
				'chat_codexbot_ts_create_bind_failures', 'om_codexbot_ts_create_bind_failures_bind_missing')
		}) or { panic(err) }
		assert bind_missing.handled
		assert bind_missing.commands.len == 1
		assert bind_missing.commands[0].text.contains('**Import Path Invalid**')
		assert bind_missing.commands[0].text.contains(missing_bind_root)
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_settings_command_controls_project_root() {
	codexbot_ts_with_temp_db('codexbot_ts_settings.sqlite', fn (_ string) {
		suffix := '${time.now().unix_milli()}'
		project_root := os.join_path(os.temp_dir(), 'codexbot_ts_settings_root_' + suffix)
		os.mkdir_all(project_root) or { panic(err) }
		defer {
			os.rmdir_all(project_root) or {}
		}

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

		empty_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_settings_empty'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_settings_empty'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_settings_empty'
			target:      'chat_codexbot_ts_settings'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/settings', 'chat_codexbot_ts_settings',
				'om_codexbot_ts_settings_empty')
		}) or { panic(err) }
		assert empty_resp.handled
		assert empty_resp.commands.len == 1
		assert empty_resp.commands[0].text.contains('**Settings**')
		assert empty_resp.commands[0].text.contains('No settings configured yet.')

		create_without_setting := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_settings_create_fail'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_settings_create_fail'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_settings_create_fail'
			target:      'chat_codexbot_ts_settings'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/create gamma', 'chat_codexbot_ts_settings',
				'om_codexbot_ts_settings_create_fail')
		}) or { panic(err) }
		assert create_without_setting.handled
		assert create_without_setting.commands.len == 1
		assert create_without_setting.commands[0].text.contains('**Project Root Missing**')

		setting_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_settings_update'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_settings_update'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_settings_update'
			target:      'chat_codexbot_ts_settings'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/setting project_root_dir ' + project_root,
				'chat_codexbot_ts_settings', 'om_codexbot_ts_settings_update')
		}) or { panic(err) }
		assert setting_resp.handled
		assert setting_resp.commands.len == 1
		assert setting_resp.commands[0].text.contains('`project_root_dir` = `' + project_root + '`')

		list_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_settings_list'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_settings_list'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_settings_list'
			target:      'chat_codexbot_ts_settings'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/settings', 'chat_codexbot_ts_settings',
				'om_codexbot_ts_settings_list')
		}) or { panic(err) }
		assert list_resp.handled
		assert list_resp.commands.len == 1
		assert list_resp.commands[0].text.contains('**Current Settings**')
		assert list_resp.commands[0].text.contains('`project_root_dir` = `' + project_root + '`')

		create_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_settings_create_ok'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_settings_create_ok'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_settings_create_ok'
			target:      'chat_codexbot_ts_settings'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/create gamma', 'chat_codexbot_ts_settings',
				'om_codexbot_ts_settings_create_ok')
		}) or { panic(err) }
		assert create_resp.handled
		assert create_resp.commands.len == 1
		assert create_resp.commands[0].text.contains('**Project Created**')
		assert create_resp.commands[0].text.contains('Project: `gamma`')
		assert os.is_dir(os.join_path(project_root, 'gamma'))
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_instances_command_normalizes_legacy_default_alias() {
	codexbot_ts_with_temp_db('codexbot_ts_instances_legacy_alias.sqlite', fn (_ string) {
		suffix := '${time.now().unix_milli()}'
		mutator_dir := os.join_path(os.temp_dir(), 'codexbot_ts_instances_legacy_alias_mutator_' + suffix)
		os.mkdir_all(mutator_dir) or { panic(err) }
		defer {
			os.rmdir_all(mutator_dir) or {}
		}

		mutator_file := os.join_path(mutator_dir, 'mutator.mts')
		mutator_source := 'import { open } from "sqlite";\n' + '\n' +
			'globalThis.__vhttpd_handle = async (ctx) => {\n' +
			'  const dbPath = process.env.CODEXBOT_TS_DB_PATH;\n' +
			'  const db = await open({ path: dbPath, busyTimeout: 5000 });\n' +
			'  await db.exec("insert into instance_registry (provider, instance, config_json, desired_state, created_at, updated_at) values (\'codex\', \'default\', \'{}\', \'connected\', 1, 1) on conflict(provider, instance) do update set config_json = excluded.config_json, desired_state = excluded.desired_state, updated_at = excluded.updated_at");\n' +
			'  await db.close();\n' +
			'  return ctx.json({ ok: true, dbPath });\n' +
			'};\n'
		os.write_file(mutator_file, mutator_source) or { panic(err) }

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
		mut mutator := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       mutator_file
			module_root:     mutator_dir
			runtime_profile: 'node'
			enable_fs:       true
		})
		defer {
			mutator.close()
		}
		mut app := App{}

		warm_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_instances_legacy_alias_warm'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_instances_legacy_alias_warm'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_instances_legacy_alias_warm'
			target:      'chat_codexbot_ts_instances_legacy_alias'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/help', 'chat_codexbot_ts_instances_legacy_alias',
				'om_codexbot_ts_instances_legacy_alias_warm')
		}) or { panic(err) }
		assert warm_resp.handled

		seed_resp := mutator.dispatch_http(mut app, HttpLogicDispatchRequest{
			method: 'GET'
			path:   '/seed'
			req: http.Request{
				method: .get
				url:    '/seed'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_instances_legacy_alias_seed'
			request_id:  'req_codexbot_ts_instances_legacy_alias_seed'
		}) or { panic(err) }
		assert seed_resp.response.status == 200

		resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_instances_legacy_alias'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_instances_legacy_alias'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_instances_legacy_alias'
			target:      'chat_codexbot_ts_instances_legacy_alias'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/instances', 'chat_codexbot_ts_instances_legacy_alias',
				'om_codexbot_ts_instances_legacy_alias')
		}) or { panic(err) }
		assert resp.handled
		assert resp.commands.len == 1
		assert resp.commands[0].content.contains('**Codex Instances**')
		assert resp.commands[0].content.contains('`main`')
		assert resp.commands[0].content.contains('`local4501`')
		assert !resp.commands[0].content.contains('`default`')
		assert !resp.commands[0].content.contains('**3.')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_codex_query_command_runs_rpc_and_formats_response() {
	codexbot_ts_with_temp_db('codexbot_ts_codex_query.sqlite', fn (_ string) {
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

		query_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_codex_query'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_codex_query'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_codex_query'
			target:      'chat_codexbot_ts_codex_query'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/codex model/list', 'chat_codexbot_ts_codex_query',
				'om_codexbot_ts_codex_query')
		}) or { panic(err) }
		assert query_resp.handled
		assert query_resp.commands.len == 2
		assert query_resp.commands[0].text.contains('**Codex RPC Query**')
		assert query_resp.commands[0].text.contains('Method: `model/list`')
		assert query_resp.commands[1].type_ == 'provider.rpc.call'
		assert query_resp.commands[1].method == 'model/list'
		assert query_resp.commands[1].params.contains('"limit":20')
		stream_id := query_resp.commands[0].stream_id
		assert stream_id != ''

		rpc_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_codex_query_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"model/list","result":{"models":[{"id":"gpt-5.4","provider":"openai"},{"id":"gpt-5.3-codex","provider":"openai"}]},"has_error":false}'
		}) or { panic(err) }
		assert rpc_resp.handled
		assert rpc_resp.commands.len == 1
		assert rpc_resp.commands[0].type_ == 'provider.message.update'
		assert rpc_resp.commands[0].content.contains('**Codex RPC**')
		assert rpc_resp.commands[0].content.contains('Method: `model/list`')
		assert rpc_resp.commands[0].content.contains('gpt-5.4')
		assert rpc_resp.commands[0].content.contains('gpt-5.3-codex')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_read_empty_and_error_are_user_visible() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_read_fallbacks.sqlite', fn (_ string) {
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

		seed_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_read_fallbacks_seed'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_read_fallbacks_seed'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_read_fallbacks_seed'
			target:      'chat_codexbot_ts_thread_read_fallbacks'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('seed latest thread', 'chat_codexbot_ts_thread_read_fallbacks',
				'om_codexbot_ts_thread_read_fallbacks_seed')
		}) or { panic(err) }
		seed_stream_id := seed_resp.commands[0].stream_id
		assert seed_stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_fallbacks_seed_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   seed_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_read_fallback_001"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_fallbacks_seed_done'
			provider:   'codex'
			instance:   'main'
			trace_id:   seed_stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{}}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_read_fallbacks_new'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_read_fallbacks_new'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_read_fallbacks_new'
			target:      'chat_codexbot_ts_thread_read_fallbacks'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/new', 'chat_codexbot_ts_thread_read_fallbacks',
				'om_codexbot_ts_thread_read_fallbacks_new')
		}) or { panic(err) }

		use_empty := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_read_fallbacks_use_empty'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_read_fallbacks_use_empty'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_read_fallbacks_use_empty'
			target:      'chat_codexbot_ts_thread_read_fallbacks'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/use latest', 'chat_codexbot_ts_thread_read_fallbacks',
				'om_codexbot_ts_thread_read_fallbacks_use_empty')
		}) or { panic(err) }
		assert use_empty.handled
		assert use_empty.commands.len == 2
		use_empty_stream_id := use_empty.commands[0].stream_id
		assert use_empty_stream_id != ''
		assert use_empty.commands[1].method == 'thread/read'

		empty_rpc := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_fallbacks_empty_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   use_empty_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_read_fallback_001","turns":[]}},"has_error":false}'
		}) or { panic(err) }
		assert empty_rpc.handled
		assert empty_rpc.commands.len == 1
		assert empty_rpc.commands[0].type_ == 'provider.message.update'
		assert empty_rpc.commands[0].content.contains('**Thread Read**')
		assert empty_rpc.commands[0].content.contains('thread_read_fallback_001')
		assert empty_rpc.commands[0].content.contains('No assistant reply was found in this thread yet.')

		use_error := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_read_fallbacks_use_error'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_read_fallbacks_use_error'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_read_fallbacks_use_error'
			target:      'chat_codexbot_ts_thread_read_fallbacks'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/use latest', 'chat_codexbot_ts_thread_read_fallbacks',
				'om_codexbot_ts_thread_read_fallbacks_use_error')
		}) or { panic(err) }
		assert use_error.handled
		assert use_error.commands.len == 2
		use_error_stream_id := use_error.commands[0].stream_id
		assert use_error_stream_id != ''

		error_rpc := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_fallbacks_error_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   use_error_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","has_error":true,"error_message":"thread read failed"}'
		}) or { panic(err) }
		assert error_rpc.handled
		assert error_rpc.commands.len == 1
		assert error_rpc.commands[0].type_ == 'provider.message.update'
		assert error_rpc.commands[0].content.contains('**Codex RPC Error**')
		assert error_rpc.commands[0].content.contains('Method: `thread/read`')
		assert error_rpc.commands[0].content.contains('thread read failed')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_codex_thread_read_uses_bound_thread_and_rejects_bad_json() {
	codexbot_ts_with_temp_db('codexbot_ts_codex_thread_read.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_codex_thread_seed'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_codex_thread_seed'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_codex_thread_seed'
			target:      'chat_codexbot_ts_codex_thread'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('seed thread', 'chat_codexbot_ts_codex_thread',
				'om_codexbot_ts_codex_thread_seed')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_codex_thread_seed_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_codex_query_001"},"has_error":false}'
		}) or { panic(err) }

		read_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_codex_thread_read'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_codex_thread_read'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_codex_thread_read'
			target:      'chat_codexbot_ts_codex_thread'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/codex thread/read', 'chat_codexbot_ts_codex_thread',
				'om_codexbot_ts_codex_thread_read')
		}) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 2
		assert read_resp.commands[1].method == 'thread/read'
		assert read_resp.commands[1].params.contains('"threadId":"thread_codex_query_001"')
		assert read_resp.commands[1].params.contains('"includeTurns":true')

		bad_json_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_codex_bad_json'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_codex_bad_json'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_codex_bad_json'
			target:      'chat_codexbot_ts_codex_thread'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/codex model/list {oops}', 'chat_codexbot_ts_codex_thread',
				'om_codexbot_ts_codex_bad_json')
		}) or { panic(err) }
		assert bad_json_resp.handled
		assert bad_json_resp.commands.len == 1
		assert bad_json_resp.commands[0].text.contains('Invalid JSON params.')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_codex_alias_commands_are_mobile_friendly() {
	codexbot_ts_with_temp_db('codexbot_ts_codex_aliases.sqlite', fn (_ string) {
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

		models_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_codex_models_alias'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_codex_models_alias'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_codex_models_alias'
			target:      'chat_codexbot_ts_codex_aliases'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/codex models', 'chat_codexbot_ts_codex_aliases',
				'om_codexbot_ts_codex_models_alias')
		}) or { panic(err) }
		assert models_resp.handled
		assert models_resp.commands.len == 2
		assert models_resp.commands[1].method == 'model/list'

		no_thread_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_codex_thread_alias_no_thread'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_codex_thread_alias_no_thread'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_codex_thread_alias_no_thread'
			target:      'chat_codexbot_ts_codex_aliases'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/codex thread', 'chat_codexbot_ts_codex_aliases',
				'om_codexbot_ts_codex_thread_alias_no_thread')
		}) or { panic(err) }
		assert no_thread_resp.handled
		assert no_thread_resp.commands.len == 1
		assert no_thread_resp.commands[0].text.contains('**Thread Required**')

		seed_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_codex_thread_alias_seed'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_codex_thread_alias_seed'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_codex_thread_alias_seed'
			target:      'chat_codexbot_ts_codex_aliases'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('seed alias thread', 'chat_codexbot_ts_codex_aliases',
				'om_codexbot_ts_codex_thread_alias_seed')
		}) or { panic(err) }
		seed_stream_id := seed_resp.commands[0].stream_id
		assert seed_stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_codex_thread_alias_seed_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   seed_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_codex_alias_001"},"has_error":false}'
		}) or { panic(err) }

		thread_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_codex_thread_alias_bound'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_codex_thread_alias_bound'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_codex_thread_alias_bound'
			target:      'chat_codexbot_ts_codex_aliases'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/codex thread', 'chat_codexbot_ts_codex_aliases',
				'om_codexbot_ts_codex_thread_alias_bound')
		}) or { panic(err) }
		assert thread_resp.handled
		assert thread_resp.commands.len == 2
		assert thread_resp.commands[0].text.contains('**Codex RPC Query**')
		assert thread_resp.commands[1].method == 'thread/read'
		assert thread_resp.commands[1].params.contains('"threadId":"thread_codex_alias_001"')

		unsupported_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_codex_unsupported'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_codex_unsupported'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_codex_unsupported'
			target:      'chat_codexbot_ts_codex_aliases'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/codex turn/start {"threadId":"x"}',
				'chat_codexbot_ts_codex_aliases', 'om_codexbot_ts_codex_unsupported')
		}) or { panic(err) }
		assert unsupported_resp.handled
		assert unsupported_resp.commands.len == 1
		assert unsupported_resp.commands[0].text.contains('**Unsupported Codex Method**')
		assert unsupported_resp.commands[0].text.contains('Method: `turn/start`')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_read_projects_assistant_message_content_arrays() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_read_content_projection.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_thread_read_content_projection_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_read_content_projection_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_read_content_projection_task'
			target:      'chat_codexbot_ts_thread_read_content_projection'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('project this thread read', 'chat_codexbot_ts_thread_read_content_projection',
				'om_codexbot_ts_thread_read_content_projection_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_content_projection_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_read_content_projection_001"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_content_projection_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turnId":"turn_read_content_projection_001","status":"inProgress","items":[]},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_content_projection_completed'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{"threadId":"thread_read_content_projection_001","turn":{"id":"turn_read_content_projection_001","items":[],"status":"completed","error":null}}}'
		}) or { panic(err) }

		read_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_content_projection_response'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_read_content_projection_001","turns":[{"id":"turn_read_content_projection_001","items":[{"type":"message","role":"assistant","content":[{"text":"line one"},{"text":"line two"}]}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 1
		assert read_resp.commands[0].type_ == 'provider.message.update'
		assert read_resp.commands[0].content.contains('line one')
		assert read_resp.commands[0].content.contains('line two')
	})
}

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
		assert first_resp.commands.len == 2

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
		stream_id := task_resp.commands[0].stream_id
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
		assert cancel_resp.commands[0].content.contains('Detached the current run from this chat.')
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
		stream_id := task_resp.commands[0].stream_id
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
		assert cancel_resp.commands[0].content.contains('**Interrupt Requested**')
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
		first_stream_id := first_task.commands[0].stream_id
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
		assert first_rpc.commands.len == 2
		assert first_rpc.commands[1].method == 'turn/start'
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
		assert second_task.commands.len == 2
		assert second_task.commands[1].type_ == 'provider.rpc.call'
		assert second_task.commands[1].method == 'turn/start'
		assert second_task.commands[1].params.contains('"threadId":"thread_existing_001"')
		assert second_task.commands[1].params.contains('"text":"second turn"')
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
		first_stream_id := first_task.commands[0].stream_id
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
		assert second_task.commands.len == 2
		assert second_task.commands[1].type_ == 'provider.rpc.call'
		assert second_task.commands[1].method == 'turn/start'
		assert second_task.commands[1].params.contains('"threadId":"thread_reuse_001"')
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
		first_stream_id := first_task.commands[0].stream_id
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
		assert second_task.commands.len == 2
		assert second_task.commands[1].method == 'turn/start'
		assert second_task.commands[1].params.contains('"threadId":"thread_recover_missing_001"')
		second_stream_id := second_task.commands[0].stream_id
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
		assert recover_resp.commands[0].type_ == 'provider.message.update'
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
		assert restart_resp.commands.len == 2
		assert restart_resp.commands[1].type_ == 'provider.rpc.call'
		assert restart_resp.commands[1].method == 'turn/start'
		assert restart_resp.commands[1].params.contains('"threadId":"thread_recover_missing_002"')
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
		assert first_delta.commands.len == 1
		assert first_delta.commands[0].content.contains('hello')

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
		assert second_delta.commands[0].content.contains('hello world')
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
		assert message_resp.commands.len == 1
		assert message_resp.commands[0].content.contains('final answer from content array')
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
		assert completed_resp.commands.len == 2
		assert completed_resp.commands[0].type_ == 'provider.message.update'
		assert completed_resp.commands[0].content.contains('**Finishing**')
		assert completed_resp.commands[1].type_ == 'provider.rpc.call'
		assert completed_resp.commands[1].method == 'thread/read'
		assert completed_resp.commands[1].params.contains('"threadId":"thread_thread_read_001"')

		read_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_turn_completed_thread_read_response'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_thread_read_001","turns":[{"id":"turn_thread_read_001","items":[{"type":"agentMessage","id":"item_thread_read_001","text":"Hello! 我在这儿。","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 1
		assert read_resp.commands[0].type_ == 'provider.message.update'
		assert read_resp.commands[0].content.contains('Hello! 我在这儿。')
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
		assert final_resp.commands.len == 1
		assert final_resp.commands[0].type_ == 'provider.message.update'
		assert final_resp.commands[0].content.contains('final answer from raw response')

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

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_commentary_after_final_answer_is_ignored() {
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
		assert final_resp.commands.len == 1
		assert final_resp.commands[0].content.contains('stable final answer')

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
		os.write_file(session_file, '{"timestamp":"2026-03-27T14:00:02.896Z","type":"event_msg","payload":{"type":"agent_message","message":"final answer from session lookup","phase":"final_answer"}}\n') or {
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
		assert idle_resp.commands.len == 2
		assert idle_resp.commands[0].type_ == 'provider.message.update'
		assert idle_resp.commands[0].content.contains('**Finishing**')
		assert idle_resp.commands[1].type_ == 'provider.rpc.call'
		assert idle_resp.commands[1].method == 'thread/read'
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
		assert error_resp.commands[0].content.contains('**Codex Error**')
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
		assert outcome.response.body.contains('Codex Error')
		assert outcome.response.body.contains('thread/start')
		assert outcome.response.body.contains('"lastEvent":"thread/start"')
		assert !outcome.response.body.contains('"completedAt":0')
	})
}
