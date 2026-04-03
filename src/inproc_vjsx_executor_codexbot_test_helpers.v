module main

import os
import json
import net.http

struct CodexbotTsTestHarness {
mut:
	executor InProcVjsxExecutor
	app      App
}

fn codexbot_ts_build_root() string {
	return os.join_path(os.temp_dir(), 'vhttpd_codexbot_ts_test_cache')
}

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

fn codexbot_ts_feishu_payload_with_event(text string, chat_id string, message_id string, event_id string, create_time string) string {
	content_json := json.encode({
		'text': text
	})
	return '{"header":{"event_id":"${event_id}","event_type":"im.message.receive_v1"},"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","create_time":"${create_time}","content":${json.encode(content_json)}}}}'
}

fn codexbot_ts_with_temp_db(db_name string, run fn (string)) {
	with_temp_sqlite_db_env('CODEXBOT_TS_DB_PATH', db_name, run)
}

fn codexbot_ts_app_file() string {
	return os.real_path(os.join_path(os.dir(@FILE), '..', 'examples', 'codexbot-app-ts',
		'app.mts'))
}

fn codexbot_ts_new_executor_with_options(thread_count int, enable_fs bool) InProcVjsxExecutor {
	app_file := codexbot_ts_app_file()
	assert os.exists(app_file)
	return new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    thread_count
		app_entry:       app_file
		module_root:     os.dir(app_file)
		build_root:      codexbot_ts_build_root()
		runtime_profile: 'node'
		enable_fs:       enable_fs
	})
}

fn codexbot_ts_new_executor(enable_fs bool) InProcVjsxExecutor {
	return codexbot_ts_new_executor_with_options(1, enable_fs)
}

fn codexbot_ts_with_harness(db_name string, enable_fs bool, run fn (mut CodexbotTsTestHarness)) {
	codexbot_ts_with_harness_config(db_name, 1, enable_fs, run)
}

fn codexbot_ts_with_harness_config(db_name string, thread_count int, enable_fs bool, run fn (mut CodexbotTsTestHarness)) {
	codexbot_ts_with_temp_db(db_name, fn [thread_count, enable_fs, run] (_ string) {
		mut harness := CodexbotTsTestHarness{
			executor: codexbot_ts_new_executor_with_options(thread_count, enable_fs)
			app:      App{}
		}
		defer {
			harness.executor.close()
		}
		run(mut harness)
	})
}

fn codexbot_ts_dispatch_feishu_message(mut executor InProcVjsxExecutor, mut app App, id string, trace_id string, chat_id string, message_id string, text string) !WorkerWebSocketUpstreamDispatchResponse {
	return executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
		mode:        'websocket_upstream'
		event:       'message'
		id:          id
		provider:    'feishu'
		instance:    'main'
		trace_id:    trace_id
		event_type:  'im.message.receive_v1'
		message_id:  message_id
		target:      chat_id
		target_type: 'chat_id'
		payload:     codexbot_ts_feishu_payload(text, chat_id, message_id)
	})
}

fn codexbot_ts_dispatch_feishu_message_with_event(mut executor InProcVjsxExecutor, mut app App, id string, trace_id string, chat_id string, message_id string, text string, event_id string, create_time string) !WorkerWebSocketUpstreamDispatchResponse {
	return executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
		mode:        'websocket_upstream'
		event:       'message'
		id:          id
		provider:    'feishu'
		instance:    'main'
		trace_id:    trace_id
		event_type:  'im.message.receive_v1'
		message_id:  message_id
		target:      chat_id
		target_type: 'chat_id'
		payload:     codexbot_ts_feishu_payload_with_event(text, chat_id, message_id, event_id,
			create_time)
	})
}

fn codexbot_ts_start_task(mut executor InProcVjsxExecutor, mut app App, id string, trace_id string, chat_id string, message_id string, text string) !(WorkerWebSocketUpstreamDispatchResponse, string) {
	resp := codexbot_ts_dispatch_feishu_message(mut executor, mut app, id, trace_id, chat_id, message_id, text)!
	return resp, codexbot_ts_first_stream_id(resp.commands)
}

fn codexbot_ts_dispatch_codex_event(mut executor InProcVjsxExecutor, mut app App, id string, stream_id string, event_type string, payload string) !WorkerWebSocketUpstreamDispatchResponse {
	return executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
		mode:       'websocket_upstream'
		event:      'message'
		id:         id
		provider:   'codex'
		instance:   'main'
		trace_id:   stream_id
		event_type: event_type
		payload:    payload
	})
}

fn (mut h CodexbotTsTestHarness) dispatch_feishu_message(id string, trace_id string, chat_id string, message_id string, text string) !WorkerWebSocketUpstreamDispatchResponse {
	return codexbot_ts_dispatch_feishu_message(mut h.executor, mut h.app, id, trace_id, chat_id,
		message_id, text)
}

fn (mut h CodexbotTsTestHarness) dispatch_feishu_message_with_event(id string, trace_id string, chat_id string, message_id string, text string, event_id string, create_time string) !WorkerWebSocketUpstreamDispatchResponse {
	return codexbot_ts_dispatch_feishu_message_with_event(mut h.executor, mut h.app, id, trace_id,
		chat_id, message_id, text, event_id, create_time)
}

fn (mut h CodexbotTsTestHarness) start_task(id string, trace_id string, chat_id string, message_id string, text string) !(WorkerWebSocketUpstreamDispatchResponse, string) {
	return codexbot_ts_start_task(mut h.executor, mut h.app, id, trace_id, chat_id, message_id,
		text)
}

fn (mut h CodexbotTsTestHarness) dispatch_feishu_thread_message(id string, trace_id string, chat_id string, message_id string, text string, root_id string, parent_id string) !WorkerWebSocketUpstreamDispatchResponse {
	return h.executor.dispatch_websocket_upstream(mut h.app, WorkerWebSocketUpstreamDispatchRequest{
		mode:        'websocket_upstream'
		event:       'message'
		id:          id
		provider:    'feishu'
		instance:    'main'
		trace_id:    trace_id
		event_type:  'im.message.receive_v1'
		message_id:  message_id
		target:      chat_id
		target_type: 'chat_id'
		payload:     codexbot_ts_feishu_thread_payload(text, chat_id, message_id, root_id, parent_id)
	})
}

fn (mut h CodexbotTsTestHarness) dispatch_codex_event(id string, stream_id string, event_type string, payload string) !WorkerWebSocketUpstreamDispatchResponse {
	return codexbot_ts_dispatch_codex_event(mut h.executor, mut h.app, id, stream_id, event_type,
		payload)
}

fn (mut h CodexbotTsTestHarness) admin_state(trace_id string, request_id string) !HttpLogicDispatchOutcome {
	return h.executor.dispatch_http(mut h.app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/admin/state'
		req:         http.Request{
			method: .get
			url:    '/admin/state'
			host:   'example.test'
		}
		remote_addr: '127.0.0.1'
		trace_id:    trace_id
		request_id:  request_id
	})
}

fn codexbot_ts_command_by_type(commands []WorkerWebSocketUpstreamCommand, type_ string) WorkerWebSocketUpstreamCommand {
	for command in commands {
		if command.type_ == type_ {
			return command
		}
	}
	assert false, 'missing command type ${type_}'
	return WorkerWebSocketUpstreamCommand{}
}

fn codexbot_ts_first_stream_id(commands []WorkerWebSocketUpstreamCommand) string {
	for command in commands {
		if command.stream_id != '' {
			return command.stream_id
		}
	}
	return ''
}
