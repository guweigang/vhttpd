module main

import executor as execmod
import upstream.transport
import net.http
import os
import json2 as json
import time

fn codexbot_semantics_payload(text string, chat_id string, message_id string) string {
	content_json := json.encode({
		'text': text
	}, escape_unicode: true, time_as_unix: true)
	return '{"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","content":${json.encode(content_json,
		escape_unicode: true
		time_as_unix:   true
	)}}}}'
}

fn codexbot_semantics_thread_payload(text string, chat_id string, message_id string, root_id string, parent_id string) string {
	content_json := json.encode({
		'text': text
	}, escape_unicode: true, time_as_unix: true)
	return '{"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","root_id":"${root_id}","parent_id":"${parent_id}","content":${json.encode(content_json,
		escape_unicode: true
		time_as_unix:   true
	)}}}}'
}

fn codexbot_semantics_payload_with_event(text string, chat_id string, message_id string, event_id string, create_time string) string {
	content_json := json.encode({
		'text': text
	}, escape_unicode: true, time_as_unix: true)
	return '{"header":{"event_id":"${event_id}","event_type":"im.message.receive_v1"},"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","create_time":"${create_time}","content":${json.encode(content_json,
		escape_unicode: true
		time_as_unix:   true
	)}}}}'
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
	return os.real_path(os.join_path(os.dir(@FILE), '..', 'examples', 'codexbot-app-ts', 'app.mts'))
}

fn test_creation_ts_derived_card_spends_the_persisted_host_ticket() {
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
		mut app := InProcTestApp{}
		task_resp := executor.dispatch_websocket_upstream(mut app, transport.WorkerWebSocketUpstreamDispatchRequest{
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
			payload:     codexbot_semantics_thread_payload('thread item card task',
				'chat_codexbot_ts_semantics_thread', 'om_codexbot_ts_semantics_thread_task',
				'om_thread_semantics_root', 'om_thread_semantics_parent')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''

		delta_resp := executor.dispatch_websocket_upstream(mut app, transport.WorkerWebSocketUpstreamDispatchRequest{
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
		send := delta_resp.commands[0]
		generation := send.metadata['stream_generation'] or { '' }
		token := send.metadata['creation_token'] or { '' }
		assert generation != '' && token != ''
		assert delta_resp.commands[1].metadata['stream_generation'] == generation
		claim := app.creation_state.admit_wire_initial_creation(send.stream_id, send.instance, generation, token) or { panic('producer did not retain its host-issued ticket through SQL') }
		assert app.creation_state.admit_wire_initial_creation(send.stream_id, send.instance, generation, token) == none
		app.creation_state.finish_initial_send(claim)
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_reuses_thread_after_restart() {
	codexbot_ts_with_temp_db('codexbot_ts_reuse_thread.sqlite', fn (_ string) {
		mut executor_a := codexbot_ts_new_executor(false)
		defer {
			executor_a.close()
		}
		mut app := InProcTestApp{}
		first_task, first_stream_id := codexbot_ts_start_task(mut executor_a, mut app,
			'codexbot_ts_reuse_task_1', 'trace_codexbot_ts_reuse_task_1', 'chat_codexbot_ts_reuse',
			'om_codexbot_reuse_task_1', 'first task') or { panic(err) }
		assert first_task.handled
		assert first_stream_id != ''
		_ = codexbot_ts_dispatch_codex_event(mut executor_a, mut app, 'codexbot_ts_reuse_rpc_1',
			first_stream_id, 'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_reuse_001"},"has_error":false}') or {
			panic(err)
		}
		_ = codexbot_ts_dispatch_codex_event(mut executor_a, mut app,
			'codexbot_ts_reuse_turn_rpc_1', first_stream_id, 'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_reuse_001"}},"has_error":false}') or {
			panic(err)
		}
		_ = codexbot_ts_dispatch_codex_event(mut executor_a, mut app,
			'codexbot_ts_reuse_completed_1', first_stream_id, 'codex.notification',
			'{"method":"turn/completed","params":{}}') or { panic(err) }
		_ = codexbot_ts_dispatch_codex_event(mut executor_a, mut app, 'codexbot_ts_reuse_read_1',
			first_stream_id, 'codex.rpc.response',
			'{"method":"thread/read","result":{"thread":{"id":"thread_reuse_001","turns":[{"id":"turn_thread_reuse_001","items":[{"type":"agentMessage","id":"item_thread_reuse_001","text":"reuse ok","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}') or {
			panic(err)
		}

		mut executor_b := codexbot_ts_new_executor(false)
		defer {
			executor_b.close()
		}
		second_task, _ := codexbot_ts_start_task(mut executor_b, mut app,
			'codexbot_ts_reuse_task_2', 'trace_codexbot_ts_reuse_task_2', 'chat_codexbot_ts_reuse',
			'om_codexbot_reuse_task_2', 'second task') or { panic(err) }
		assert second_task.handled
		assert second_task.commands.len == 1
		assert second_task.commands[0].type_ == 'provider.rpc.call'
		assert second_task.commands[0].method == 'turn/start'
		assert second_task.commands[0].params.contains('"threadId":"thread_reuse_001"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_restores_stream_draft_after_restart() {
	codexbot_ts_with_temp_db('codexbot_ts_restore_draft.sqlite', fn (_ string) {
		mut executor_a := codexbot_ts_new_executor(false)
		defer {
			executor_a.close()
		}
		mut app := InProcTestApp{}
		task_resp, stream_id := codexbot_ts_start_task(mut executor_a, mut app,
			'codexbot_ts_restore_task_1', 'trace_codexbot_ts_restore_task_1',
			'chat_codexbot_ts_restore', 'om_codexbot_restore_task_1', 'draft task') or {
			panic(err)
		}
		assert task_resp.handled
		assert stream_id != ''
		first_delta := codexbot_ts_dispatch_codex_event(mut executor_a, mut app,
			'codexbot_ts_restore_delta_1', stream_id, 'codex.notification',
			'{"method":"item/agentMessage/delta","params":{"delta":"hello "}}') or { panic(err) }
		assert first_delta.handled
		assert first_delta.commands.len == 2
		assert first_delta.commands[0].type_ == 'provider.message.send'
		assert first_delta.commands[1].type_ == 'stream.append'
		assert first_delta.commands[1].text == 'hello '
		item_stream_id := first_delta.commands[1].stream_id
		assert item_stream_id != ''
		assert item_stream_id == first_delta.commands[0].stream_id

		mut executor_b := codexbot_ts_new_executor(false)
		defer {
			executor_b.close()
		}
		second_delta := codexbot_ts_dispatch_codex_event(mut executor_b, mut app,
			'codexbot_ts_restore_delta_2', stream_id, 'codex.notification',
			'{"method":"item/agentMessage/delta","params":{"delta":"world"}}') or { panic(err) }
		assert second_delta.handled
		assert second_delta.commands.len == 2
		assert second_delta.commands[0].type_ == 'provider.message.send'
		assert second_delta.commands[0].stream_id == item_stream_id
		assert second_delta.commands[1].type_ == 'stream.append'
		assert second_delta.commands[1].stream_id == item_stream_id
		assert second_delta.commands[1].text == 'world'
	})
}
