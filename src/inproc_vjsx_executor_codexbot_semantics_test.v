module main

import net.http
import os
import json
import time

fn codexbot_semantics_payload(text string, chat_id string, message_id string) string {
	content_json := json.encode({
		'text': text
	})
	return '{"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","content":${json.encode(content_json)}}}}'
}

fn codexbot_semantics_thread_payload(text string, chat_id string, message_id string, root_id string, parent_id string) string {
	content_json := json.encode({
		'text': text
	})
	return '{"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","root_id":"${root_id}","parent_id":"${parent_id}","content":${json.encode(content_json)}}}}'
}

fn codexbot_semantics_payload_with_event(text string, chat_id string, message_id string, event_id string, create_time string) string {
	content_json := json.encode({
		'text': text
	})
	return '{"header":{"event_id":"${event_id}","event_type":"im.message.receive_v1"},"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","create_time":"${create_time}","content":${json.encode(content_json)}}}}'
}

fn codexbot_semantics_with_temp_db(db_name string, run fn ()) {
	prev_db := os.getenv('CODEXBOT_TS_DB_PATH')
	db_path := os.join_path(os.temp_dir(), '${time.now().unix_micro()}_${db_name}')
	os.setenv('CODEXBOT_TS_DB_PATH', db_path, true)
	defer {
		if prev_db == '' {
			os.unsetenv('CODEXBOT_TS_DB_PATH')
		} else {
			os.setenv('CODEXBOT_TS_DB_PATH', prev_db, true)
		}
		os.rm(db_path) or {}
		os.rm('${db_path}-shm') or {}
		os.rm('${db_path}-wal') or {}
	}
	run()
}

fn codexbot_semantics_app_file() string {
	return os.real_path(os.join_path(os.dir(@FILE), '..', 'examples', 'codexbot-app-ts',
		'app.mts'))
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_active_thread_status_does_not_overwrite_run_status() {
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_active.sqlite', fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_active_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_active_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_active_task'
			target:      'chat_codexbot_ts_semantics_active'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('start active semantics task', 'chat_codexbot_ts_semantics_active',
				'om_codexbot_ts_semantics_active_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_active_thread_started'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_semantics_active_001"},"has_error":false}'
		}) or { panic(err) }

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_active_turn_started'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_semantics_active_001"}},"has_error":false}'
		}) or { panic(err) }

		active_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_active_status'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"thread/status/changed","params":{"threadId":"thread_semantics_active_001","status":{"type":"active","activeFlags":["waitingOnUserInput"]}}}'
		}) or { panic(err) }
		assert active_resp.handled
		assert active_resp.commands.len == 0

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_semantics_active_state'
			request_id:  'req_codexbot_ts_semantics_active_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"status":"running"')
		assert !state_resp.response.body.contains('"status":"active"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_structured_error_notification_uses_codex_error_info() {
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_error.sqlite', fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_error_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_error_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_error_task'
			target:      'chat_codexbot_ts_semantics_error'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('start error semantics task', 'chat_codexbot_ts_semantics_error',
				'om_codexbot_ts_semantics_error_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		error_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_error_notif'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"error","params":{"threadId":"thread_semantics_error_001","turnId":"turn_semantics_error_001","willRetry":false,"error":{"message":"request failed","codexErrorInfo":{"responseStreamConnectionFailed":{"httpStatusCode":502}},"additionalDetails":"gateway dropped"}}}'
		}) or { panic(err) }
		assert error_resp.handled
		assert error_resp.commands.len == 1
		assert error_resp.commands[0].type_ == 'provider.message.send'
		assert error_resp.commands[0].content.contains('request failed')
		assert error_resp.commands[0].content.contains('Response Stream Connection Failed')
		assert error_resp.commands[0].content.contains('502')
		assert error_resp.commands[0].content.contains('gateway dropped')

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_semantics_error_state'
			request_id:  'req_codexbot_ts_semantics_error_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"status":"error"')
		assert state_resp.response.body.contains('Response Stream Connection Failed')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_realtime_error_is_treated_as_error() {
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_thread_realtime_error.sqlite', fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_thread_realtime_error_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_thread_realtime_error_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_thread_realtime_error_task'
			target:      'chat_codexbot_ts_semantics_thread_realtime_error'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('start realtime error semantics task', 'chat_codexbot_ts_semantics_thread_realtime_error',
				'om_codexbot_ts_semantics_thread_realtime_error_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		error_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_thread_realtime_error_notif'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"thread/realtime/error","params":{"threadId":"thread_semantics_realtime_error_001","message":"realtime transport failed"}}'
		}) or { panic(err) }
		assert error_resp.handled
		assert error_resp.commands.len == 1
		assert error_resp.commands[0].type_ == 'provider.message.send'
		assert error_resp.commands[0].content.contains('realtime transport failed')

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_semantics_thread_realtime_error_state'
			request_id:  'req_codexbot_ts_semantics_thread_realtime_error_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"status":"error"')
		assert state_resp.response.body.contains('realtime transport failed')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_system_error_status_uses_thread_level_fallback_text() {
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_system_error.sqlite', fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_system_error_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_system_error_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_system_error_task'
			target:      'chat_codexbot_ts_semantics_system_error'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('start system error semantics task',
				'chat_codexbot_ts_semantics_system_error', 'om_codexbot_ts_semantics_system_error_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		error_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_system_error_notif'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"thread/status/changed","params":{"threadId":"thread_semantics_system_error_001","status":{"type":"systemError"}}}'
		}) or { panic(err) }
		assert error_resp.handled
		assert error_resp.commands.len == 1
		assert error_resp.commands[0].type_ == 'provider.message.send'
		assert error_resp.commands[0].content.contains('systemError')
		assert error_resp.commands[0].content.contains('did not include structured error details')
		assert !error_resp.commands[0].content.contains('Response Stream Connection Failed')

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_semantics_system_error_state'
			request_id:  'req_codexbot_ts_semantics_system_error_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"status":"error"')
		assert state_resp.response.body.contains('systemError')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_item_cards_reply_in_thread() {
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_thread_cards.sqlite', fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_thread_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_thread_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_thread_task'
			target:      'chat_codexbot_ts_semantics_thread'
			target_type: 'chat_id'
			payload:     codexbot_semantics_thread_payload('thread item card task', 'chat_codexbot_ts_semantics_thread',
				'om_codexbot_ts_semantics_thread_task', 'om_thread_semantics_root', 'om_thread_semantics_parent')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		delta_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_thread_delta'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/agentMessage/delta","params":{"threadId":"thread_semantics_thread_001","turnId":"turn_semantics_thread_001","itemId":"item_semantics_thread_001","phase":"commentary","delta":"hello in thread card"}}'
		}) or { panic(err) }
		assert delta_resp.handled
		assert delta_resp.commands.len == 2
		assert delta_resp.commands[0].type_ == 'provider.message.send'
		assert delta_resp.commands[0].target_type == 'message_id'
		assert delta_resp.commands[0].target == 'om_thread_semantics_root'
		assert delta_resp.commands[1].type_ == 'stream.append'
		assert delta_resp.commands[1].text == 'hello in thread card'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_commentary_after_final_answer_uses_separate_item_card() {
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_commentary_after_final.sqlite',
		fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_commentary_after_final_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_commentary_after_final_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_commentary_after_final_task'
			target:      'chat_codexbot_ts_semantics_commentary_after_final'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('commentary after final semantics task',
				'chat_codexbot_ts_semantics_commentary_after_final', 'om_codexbot_ts_semantics_commentary_after_final_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		final_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_commentary_after_final_final'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/completed","params":{"threadId":"thread_semantics_commentary_after_final_001","turnId":"turn_semantics_commentary_after_final_001","item":{"id":"item_semantics_commentary_after_final_001","type":"agentMessage","phase":"final_answer","text":"stable semantics final answer"}}}'
		}) or { panic(err) }
		assert final_resp.handled
		assert final_resp.commands.len == 3
		assert final_resp.commands[0].type_ == 'provider.message.send'
		assert final_resp.commands[1].type_ == 'stream.append'
		assert final_resp.commands[1].text == 'stable semantics final answer'
		assert final_resp.commands[2].type_ == 'stream.finish'
		final_item_stream_id := final_resp.commands[1].stream_id
		assert final_item_stream_id != ''

		commentary_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_commentary_after_final_commentary'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/completed","params":{"threadId":"thread_semantics_commentary_after_final_001","turnId":"turn_semantics_commentary_after_final_001","item":{"id":"item_semantics_commentary_after_final_002","type":"agentMessage","phase":"commentary","text":"this semantics commentary should not replace the answer"}}}'
		}) or { panic(err) }
		assert commentary_resp.handled
		assert commentary_resp.commands.len == 3
		assert commentary_resp.commands[0].type_ == 'provider.message.send'
		assert commentary_resp.commands[1].type_ == 'stream.append'
		assert commentary_resp.commands[1].text == 'this semantics commentary should not replace the answer'
		assert commentary_resp.commands[2].type_ == 'stream.finish'
		commentary_item_stream_id := commentary_resp.commands[1].stream_id
		assert commentary_item_stream_id != final_item_stream_id

		idle_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_commentary_after_final_idle'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"thread/status/changed","params":{"threadId":"thread_semantics_commentary_after_final_001","status":{"type":"idle"}}}'
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
			trace_id:    'trace_codexbot_ts_semantics_commentary_after_final_state'
			request_id:  'req_codexbot_ts_semantics_commentary_after_final_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"resultText":"stable semantics final answer"')
		assert state_resp.response.body.contains('"streamId":"' + final_item_stream_id + '"')
		assert state_resp.response.body.contains('"streamId":"' + commentary_item_stream_id + '"')
		assert state_resp.response.body.contains('"resultText":"this semantics commentary should not replace the answer"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_start_continues_into_turn_start() {
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_thread_continue.sqlite', fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_continue_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_continue_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_continue_task'
			target:      'chat_codexbot_ts_semantics_continue'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('continue thread into turn', 'chat_codexbot_ts_semantics_continue',
				'om_codexbot_ts_semantics_continue_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		rpc_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_continue_thread_started'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_semantics_continue_001"},"has_error":false}'
		}) or { panic(err) }
		assert rpc_resp.handled
		assert rpc_resp.commands.len == 1
		assert rpc_resp.commands[0].type_ == 'provider.rpc.call'
		assert rpc_resp.commands[0].method == 'turn/start'
		assert rpc_resp.commands[0].stream_id == stream_id
		assert rpc_resp.commands[0].params.contains('"threadId":"thread_semantics_continue_001"')

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_semantics_continue_state'
			request_id:  'req_codexbot_ts_semantics_continue_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"status":"starting_turn"')
		assert state_resp.response.body.contains('"threadId":"thread_semantics_continue_001"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_read_prefers_current_turn_answer() {
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_thread_read_current_turn.sqlite',
		fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_thread_read_current_turn_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_thread_read_current_turn_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_thread_read_current_turn_task'
			target:      'chat_codexbot_ts_semantics_thread_read_current_turn'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('show me latest turn semantics only',
				'chat_codexbot_ts_semantics_thread_read_current_turn', 'om_codexbot_ts_semantics_thread_read_current_turn_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_thread_read_current_turn_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_semantics_thread_read_current_turn_001"},"has_error":false}'
		}) or { panic(err) }

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_thread_read_current_turn_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_semantics_thread_read_current_turn_001"}},"has_error":false}'
		}) or { panic(err) }

		read_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_thread_read_current_turn_response'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_semantics_thread_read_current_turn_001","turns":[{"id":"turn_semantics_thread_read_old_001","items":[{"type":"agentMessage","id":"item_semantics_thread_read_old_001","text":"old final answer","phase":"final_answer"}],"status":"completed","error":null},{"id":"turn_semantics_thread_read_current_turn_001","items":[{"type":"agentMessage","id":"item_semantics_thread_read_current_001","text":"new answer from current turn","phase":"commentary"}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 2
		assert read_resp.commands[0].type_ == 'provider.message.send'
		assert read_resp.commands[1].type_ == 'stream.append'
		assert read_resp.commands[1].text.contains('new answer from current turn')
		assert !read_resp.commands[1].text.contains('old final answer')

		state_resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/admin/state'
			req:         http.Request{
				method: .get
				url:    '/admin/state'
				host:   'example.test'
			}
			remote_addr: '127.0.0.1'
			trace_id:    'trace_codexbot_ts_semantics_thread_read_current_turn_state'
			request_id:  'req_codexbot_ts_semantics_thread_read_current_turn_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"status":"completed"')
		assert state_resp.response.body.contains('new answer from current turn')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_stale_busy_stream_detaches_before_next_prompt() {
	prev_stale := os.getenv('CODEXBOT_TS_ACTIVE_STREAM_STALE_MS')
	os.setenv('CODEXBOT_TS_ACTIVE_STREAM_STALE_MS', '1', true)
	defer {
		if prev_stale == '' {
			os.unsetenv('CODEXBOT_TS_ACTIVE_STREAM_STALE_MS')
		} else {
			os.setenv('CODEXBOT_TS_ACTIVE_STREAM_STALE_MS', prev_stale, true)
		}
	}
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_stale_busy.sqlite', fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_stale_busy_first'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_stale_busy_first'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_stale_busy_first'
			target:      'chat_codexbot_ts_semantics_stale_busy'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('first stale semantics task', 'chat_codexbot_ts_semantics_stale_busy',
				'om_codexbot_ts_semantics_stale_busy_first')
		}) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1

		time.sleep(5 * time.millisecond)

		second_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_semantics_stale_busy_second'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_stale_busy_second'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_stale_busy_second'
			target:      'chat_codexbot_ts_semantics_stale_busy'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('second semantics task should proceed',
				'chat_codexbot_ts_semantics_stale_busy', 'om_codexbot_ts_semantics_stale_busy_second')
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
			trace_id:    'trace_codexbot_ts_semantics_stale_busy_state'
			request_id:  'req_codexbot_ts_semantics_stale_busy_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"lastEvent":"stale.auto_detach"')
		assert state_resp.response.body.contains('second semantics task should proceed')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_busy_guard_isolated_to_same_feishu_thread() {
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_thread_busy_guard.sqlite',
		fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_thread_busy_first'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_thread_busy_first'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_thread_busy_first'
			target:      'chat_codexbot_ts_semantics_thread_busy'
			target_type: 'chat_id'
			payload:     codexbot_semantics_thread_payload('thread busy first semantics',
				'chat_codexbot_ts_semantics_thread_busy', 'om_codexbot_ts_semantics_thread_busy_first',
				'om_semantics_thread_busy_root', 'om_semantics_thread_busy_parent')
		}) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1

		second_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_semantics_thread_busy_second'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_thread_busy_second'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_thread_busy_second'
			target:      'chat_codexbot_ts_semantics_thread_busy'
			target_type: 'chat_id'
			payload:     codexbot_semantics_thread_payload('thread busy second semantics',
				'chat_codexbot_ts_semantics_thread_busy', 'om_codexbot_ts_semantics_thread_busy_second',
				'om_semantics_thread_busy_root', 'om_semantics_thread_busy_parent_2')
		}) or { panic(err) }
		assert second_resp.handled
		assert second_resp.commands.len == 1
		assert second_resp.commands[0].type_ == 'provider.message.send'
		assert second_resp.commands[0].target_type == 'message_id'
		assert second_resp.commands[0].target == 'om_codexbot_ts_semantics_thread_busy_second'
		assert second_resp.commands[0].text.contains('Still working on the previous request in this thread.')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_dedupes_replayed_feishu_message_by_message_id() {
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_dedup_message_id.sqlite', fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_dedup_message_first'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_dedup_message_first'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_dedup_same'
			target:      'chat_codexbot_ts_semantics_dedup_message'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('dedupe this semantics message', 'chat_codexbot_ts_semantics_dedup_message',
				'om_codexbot_ts_semantics_dedup_same')
		}) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].stream_id != ''

		replay_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_semantics_dedup_message_replay'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_dedup_message_replay'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_dedup_same'
			target:      'chat_codexbot_ts_semantics_dedup_message'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('dedupe this semantics message', 'chat_codexbot_ts_semantics_dedup_message',
				'om_codexbot_ts_semantics_dedup_same')
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
			trace_id:    'trace_codexbot_ts_semantics_dedup_message_state'
			request_id:  'req_codexbot_ts_semantics_dedup_message_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('dedupe this semantics message')
		assert state_resp.response.body.split('dedupe this semantics message').len == 2
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_dedupes_replayed_feishu_message_by_event_id() {
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_dedup_event_id.sqlite', fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_dedup_event_first'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_dedup_event_first'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_dedup_event_first'
			target:      'chat_codexbot_ts_semantics_dedup_event'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload_with_event('dedupe this semantics event',
				'chat_codexbot_ts_semantics_dedup_event', 'om_codexbot_ts_semantics_dedup_event_first',
				'evt_codexbot_ts_semantics_dedup_event', '1710000000')
		}) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].stream_id != ''

		replay_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_semantics_dedup_event_replay'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_dedup_event_replay'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_dedup_event_second'
			target:      'chat_codexbot_ts_semantics_dedup_event'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload_with_event('dedupe this semantics event',
				'chat_codexbot_ts_semantics_dedup_event', 'om_codexbot_ts_semantics_dedup_event_second',
				'evt_codexbot_ts_semantics_dedup_event', '1710000000')
		}) or { panic(err) }
		assert replay_resp.handled
		assert replay_resp.commands.len == 0
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_turn_completed_prefers_final_answer_from_turn_items() {
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_turn_completed_turn_items.sqlite',
		fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_turn_completed_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_turn_completed_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_turn_completed_task'
			target:      'chat_codexbot_ts_semantics_turn_completed'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('hello', 'chat_codexbot_ts_semantics_turn_completed',
				'om_codexbot_ts_semantics_turn_completed_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_turn_completed_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_semantics_turn_items_001"},"has_error":false}'
		}) or { panic(err) }

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_turn_completed_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turn":{"id":"turn_semantics_turn_items_001"}},"has_error":false}'
		}) or { panic(err) }

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_turn_completed_delta'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"item/agentMessage/delta","params":{"threadId":"thread_semantics_turn_items_001","turnId":"turn_semantics_turn_items_001","delta":"draft commentary"}}'
		}) or { panic(err) }

		completed_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_turn_completed_done'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{"threadId":"thread_semantics_turn_items_001","turn":{"id":"turn_semantics_turn_items_001","items":[{"type":"agentMessage","id":"item_semantics_turn_items_001","phase":"commentary","text":"draft commentary"},{"type":"agentMessage","id":"item_semantics_turn_items_002","phase":"final_answer","text":"final answer from semantics turn items"}],"status":"completed","error":null}}}'
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
			trace_id:    'trace_codexbot_ts_semantics_turn_completed_state'
			request_id:  'req_codexbot_ts_semantics_turn_completed_state'
		}) or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"status":"completed"')
		assert state_resp.response.body.contains('"resultText":"final answer from semantics turn items"')
		assert state_resp.response.body.contains('"lastEvent":"turn/completed"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_rename_error_restores_previous_name() {
	codexbot_semantics_with_temp_db('codexbot_ts_semantics_rename_rollback.sqlite', fn () {
		app_file := codexbot_semantics_app_file()
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
			id:          'codexbot_ts_semantics_rename_seed'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_rename_seed'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_rename_seed'
			target:      'chat_codexbot_ts_semantics_rename'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('seed rename semantics thread', 'chat_codexbot_ts_semantics_rename',
				'om_codexbot_ts_semantics_rename_seed')
		}) or { panic(err) }
		first_stream_id := first_task.commands[0].stream_id
		assert first_stream_id != ''

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_rename_seed_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_semantics_rename_001"},"has_error":false}'
		}) or { panic(err) }

		rename_original := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_semantics_rename_original_cmd'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_rename_original_cmd'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_rename_original_cmd'
			target:      'chat_codexbot_ts_semantics_rename'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('/thread rename Original Name', 'chat_codexbot_ts_semantics_rename',
				'om_codexbot_ts_semantics_rename_original_cmd')
		}) or { panic(err) }
		original_rename_stream_id := rename_original.commands[0].stream_id
		assert original_rename_stream_id != ''

		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_rename_original_done'
			provider:   'codex'
			instance:   'main'
			trace_id:   original_rename_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/name/set","result":{"thread":{"id":"thread_semantics_rename_001","name":"Original Name"}},"has_error":false}'
		}) or { panic(err) }

		rename_broken := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_semantics_rename_broken_cmd'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_rename_broken_cmd'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_rename_broken_cmd'
			target:      'chat_codexbot_ts_semantics_rename'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('/thread rename Broken Name', 'chat_codexbot_ts_semantics_rename',
				'om_codexbot_ts_semantics_rename_broken_cmd')
		}) or { panic(err) }
		assert rename_broken.handled
		assert rename_broken.commands.len == 2
		assert rename_broken.commands[0].text.contains('Broken Name')
		assert rename_broken.commands[1].method == 'thread/name/set'
		broken_rename_stream_id := rename_broken.commands[0].stream_id
		assert broken_rename_stream_id != ''

		pending_thread_view := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_semantics_rename_pending_view'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_rename_pending_view'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_rename_pending_view'
			target:      'chat_codexbot_ts_semantics_rename'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('/thread', 'chat_codexbot_ts_semantics_rename',
				'om_codexbot_ts_semantics_rename_pending_view')
		}) or { panic(err) }
		assert pending_thread_view.handled
		assert pending_thread_view.commands.len == 1
		assert pending_thread_view.commands[0].text.contains('Broken Name')

		error_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_semantics_rename_broken_error'
			provider:   'codex'
			instance:   'main'
			trace_id:   broken_rename_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/name/set","result":{"thread":{"id":"thread_semantics_rename_001"}},"has_error":true,"error":{"message":"rename failed"}}'
		}) or { panic(err) }
		assert error_resp.handled
		assert error_resp.commands.len == 1
		assert error_resp.commands[0].type_ == 'provider.message.update'
		assert error_resp.commands[0].content.contains('rename failed')

		thread_view := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_semantics_rename_view_after_error'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_semantics_rename_view_after_error'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_semantics_rename_view_after_error'
			target:      'chat_codexbot_ts_semantics_rename'
			target_type: 'chat_id'
			payload:     codexbot_semantics_payload('/thread', 'chat_codexbot_ts_semantics_rename',
				'om_codexbot_ts_semantics_rename_view_after_error')
		}) or { panic(err) }
		assert thread_view.handled
		assert thread_view.commands.len == 1
		assert thread_view.commands[0].text.contains('- Name: Original Name')
		assert !thread_view.commands[0].text.contains('- Name: Broken Name')
	})
}
