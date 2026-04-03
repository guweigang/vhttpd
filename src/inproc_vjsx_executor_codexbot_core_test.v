module main

import net.http
import os
import time

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_boots_in_isolation() {
	codexbot_ts_with_harness('codexbot_ts_boot_isolation.sqlite', false, fn (mut harness CodexbotTsTestHarness) {
		resp := harness.dispatch_feishu_message(
			'codexbot_ts_boot_isolation',
			'trace_codexbot_ts_boot_isolation',
			'chat_codexbot_boot_isolation',
			'om_codexbot_boot_isolation',
			'/help'
		) or { panic(err) }
		assert resp.handled
		assert resp.commands.len > 0
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_handles_help_and_task_flow() {
	codexbot_ts_with_harness('codexbot_ts_help_and_task.sqlite', false, fn (mut harness CodexbotTsTestHarness) {
		help_resp := harness.dispatch_feishu_message(
			'codexbot_ts_help',
			'trace_codexbot_ts_help',
			'chat_codexbot_ts',
			'om_codexbot_help',
			'/help'
		) or { panic(err) }
		assert help_resp.handled
		assert help_resp.commands.len == 1
		assert help_resp.commands[0].type_ == 'provider.message.send'
		assert help_resp.commands[0].provider == 'feishu'
		assert help_resp.commands[0].text.contains('/project [project_key]')

		task_resp, _ := harness.start_task(
			'codexbot_ts_task',
			'trace_codexbot_ts_task',
			'chat_codexbot_ts',
			'om_codexbot_task',
			'please inspect this bug'
		) or { panic(err) }
		assert task_resp.handled
		assert task_resp.commands.len == 1
		assert task_resp.commands[0].type_ == 'provider.rpc.call'
		assert task_resp.commands[0].provider == 'codex'
		assert task_resp.commands[0].method == 'thread/start'
		assert task_resp.commands[0].stream_id.starts_with('codex:ts_')
		assert task_resp.commands[0].params.contains('"experimentalRawEvents":true')
		assert task_resp.commands[0].params.contains('"persistExtendedHistory":true')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_handles_codex_callbacks() {
	codexbot_ts_with_harness('codexbot_ts_callbacks.sqlite', false, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_task_2',
			'trace_codexbot_ts_task_2',
			'chat_codexbot_ts_2',
			'om_codexbot_task_2',
			'run a task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		rpc_resp := harness.dispatch_codex_event(
			'codexbot_ts_rpc',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_ts_001"},"has_error":false}'
		) or { panic(err) }
		assert rpc_resp.handled
		assert rpc_resp.commands.len == 1
		assert rpc_resp.commands[0].type_ == 'provider.rpc.call'
		assert rpc_resp.commands[0].method == 'turn/start'
		assert rpc_resp.commands[0].stream_id == stream_id

		turn_resp := harness.dispatch_codex_event(
			'codexbot_ts_turn_rpc',
			stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_ts_001"}},"has_error":false}'
		) or { panic(err) }
		assert turn_resp.handled
		assert turn_resp.commands.len == 0

		notif_resp := harness.dispatch_codex_event(
			'codexbot_ts_notif',
			stream_id,
			'codex.notification',
			'{"method":"item/agentMessage/delta","params":{"delta":"hello from codex"}}'
		) or { panic(err) }
		assert notif_resp.handled
		assert notif_resp.commands.len == 2
		assert notif_resp.commands[0].type_ == 'provider.message.send'
		assert notif_resp.commands[0].stream_id != ''
		assert notif_resp.commands[0].stream_id == stream_id
		assert notif_resp.commands[1].type_ == 'stream.append'
		assert notif_resp.commands[1].stream_id == stream_id
		assert notif_resp.commands[1].text == 'hello from codex'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_decodes_command_exec_output_delta_base64() {
	codexbot_ts_with_harness('codexbot_ts_command_exec_output_delta.sqlite', false, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_command_exec_output_delta_task',
			'trace_codexbot_ts_command_exec_output_delta_task',
			'chat_codexbot_ts_command_exec_output_delta',
			'om_codexbot_command_exec_output_delta_task',
			'run command delta task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		notif_resp := harness.dispatch_codex_event(
			'codexbot_ts_command_exec_output_delta_notif',
			stream_id,
			'codex.notification',
			'{"method":"command/exec/outputDelta","params":{"processId":"proc_001","stream":"stdout","deltaBase64":"aGVsbG8gd29ybGQK","capReached":false}}'
		) or { panic(err) }
		assert notif_resp.handled
		assert notif_resp.commands.len == 2
		assert notif_resp.commands[0].type_ == 'provider.message.send'
		assert notif_resp.commands[0].stream_id == stream_id
		assert notif_resp.commands[1].type_ == 'stream.append'
		assert notif_resp.commands[1].stream_id == stream_id
		assert notif_resp.commands[1].text == 'hello world\n'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_active_status_keeps_running_without_overwriting_message() {
	codexbot_ts_with_harness('codexbot_ts_active_status.sqlite', false, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_active_status_task',
			'trace_codexbot_ts_active_status_task',
			'chat_codexbot_ts_active_status',
			'om_codexbot_active_status_task',
			'run active status task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ = harness.dispatch_codex_event(
			'codexbot_ts_active_status_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_active_001"},"has_error":false}'
		) or { panic(err) }

		_ = harness.dispatch_codex_event(
			'codexbot_ts_active_status_turn',
			stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_active_001"}},"has_error":false}'
		) or { panic(err) }

		active_resp := harness.dispatch_codex_event(
			'codexbot_ts_active_status_notif',
			stream_id,
			'codex.notification',
			'{"method":"thread/status/changed","params":{"threadId":"thread_active_001","status":{"type":"active","activeFlags":[]}}}'
		) or { panic(err) }
		assert active_resp.handled
		assert active_resp.commands.len == 0

		state_resp := harness.admin_state('trace_codexbot_ts_active_status_state',
			'codexbot_ts_active_status_state') or { panic(err) }
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"status":"running"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_ignores_feishu_message_read_events() {
	mut executor := codexbot_ts_new_executor(false)
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
	codexbot_ts_with_harness_config('codexbot_ts_read_after_notif.sqlite', 2, false, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_task_3',
			'trace_codexbot_ts_task_3',
			'chat_codexbot_ts_3',
			'om_codexbot_task_3',
			'run another task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		notif_resp := harness.dispatch_codex_event(
			'codexbot_ts_thread_started',
			stream_id,
			'codex.notification',
			'{"method":"thread/started","params":{"thread":{"id":"thread_ts_003","status":{"type":"idle"}}}}'
		) or { panic(err) }
		assert notif_resp.handled
		assert notif_resp.commands.len == 1
		assert notif_resp.commands[0].type_ == 'provider.rpc.call'
		assert notif_resp.commands[0].method == 'turn/start'
		assert notif_resp.commands[0].params.contains('"threadId":"thread_ts_003"')

		read_resp := harness.executor.dispatch_websocket_upstream(mut harness.app, WorkerWebSocketUpstreamDispatchRequest{
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
	codexbot_ts_with_harness('codexbot_ts_thread_cmd.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_thread_cmd_task',
			'trace_codexbot_ts_thread_cmd_task',
			'chat_codexbot_ts_thread_cmd',
			'om_codexbot_thread_cmd_task',
			'thread aware task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ = harness.dispatch_codex_event(
			'codexbot_ts_thread_cmd_rpc',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_cmd_001"},"has_error":false}'
		) or { panic(err) }

		thread_resp := harness.dispatch_feishu_message(
			'codexbot_ts_thread_cmd_query',
			'trace_codexbot_ts_thread_cmd_query',
			'chat_codexbot_ts_thread_cmd',
			'om_codexbot_thread_cmd_query',
			'/thread'
		) or { panic(err) }
		assert thread_resp.handled
		assert thread_resp.commands.len == 1
		assert thread_resp.commands[0].text.contains('Current thread: `thread_cmd_001`')
		assert thread_resp.commands[0].text.contains('Last Stream: `' + stream_id + '`')
		assert thread_resp.commands[0].text.contains('Last Status: `starting_turn`')

		new_resp := harness.dispatch_feishu_message(
			'codexbot_ts_thread_cmd_new',
			'trace_codexbot_ts_thread_cmd_new',
			'chat_codexbot_ts_thread_cmd',
			'om_codexbot_thread_cmd_new',
			'/new'
		) or { panic(err) }
		assert new_resp.handled
		assert new_resp.commands.len == 1
		assert new_resp.commands[0].text.contains('**New Conversation**')
		assert new_resp.commands[0].text.contains('Previous Thread: `thread_cmd_001`')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_rejects_parallel_task_in_same_chat() {
	codexbot_ts_with_harness('codexbot_ts_busy_guard.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		first_resp := harness.dispatch_feishu_message(
			'codexbot_ts_busy_first',
			'trace_codexbot_ts_busy_first',
			'chat_codexbot_ts_busy',
			'om_codexbot_busy_first',
			'first active task'
		) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'
		assert first_resp.commands[0].stream_id != ''

		second_resp := harness.dispatch_feishu_message(
			'codexbot_ts_busy_second',
			'trace_codexbot_ts_busy_second',
			'chat_codexbot_ts_busy',
			'om_codexbot_busy_second',
			'second overlapping task'
		) or { panic(err) }
		assert second_resp.handled
		assert second_resp.commands.len == 1
		assert second_resp.commands[0].type_ == 'provider.message.send'
		assert second_resp.commands[0].stream_id == ''
		assert second_resp.commands[0].text.contains('Still working on the previous request.')
		assert second_resp.commands[0].text.contains('`/cancel`')

		state_resp := harness.admin_state('trace_codexbot_ts_busy_state',
			'req_codexbot_ts_busy_state') or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('first active task')
		assert !state_resp.response.body.contains('second overlapping task')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_dedupes_replayed_feishu_message() {
	codexbot_ts_with_harness('codexbot_ts_feishu_dedup.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		first_resp := harness.dispatch_feishu_message(
			'codexbot_ts_dedup_first',
			'trace_codexbot_ts_dedup_first',
			'chat_codexbot_ts_dedup',
			'om_codexbot_dedup_same',
			'dedupe this inbound event'
		) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'
		assert first_resp.commands[0].stream_id != ''

		replay_resp := harness.dispatch_feishu_message(
			'codexbot_ts_dedup_replay',
			'trace_codexbot_ts_dedup_replay',
			'chat_codexbot_ts_dedup',
			'om_codexbot_dedup_same',
			'dedupe this inbound event'
		) or { panic(err) }
		assert replay_resp.handled
		assert replay_resp.commands.len == 0

		state_resp := harness.admin_state('trace_codexbot_ts_dedup_state',
			'req_codexbot_ts_dedup_state') or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('dedupe this inbound event')
		assert state_resp.response.body.split('dedupe this inbound event').len == 2
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_dedupes_replayed_feishu_message_across_lanes() {
	codexbot_ts_with_harness_config('codexbot_ts_feishu_dedup_across_lanes.sqlite', 2, true, fn (mut harness CodexbotTsTestHarness) {
		first_resp := harness.dispatch_feishu_message(
			'codexbot_ts_dedup_lane_first',
			'trace_codexbot_ts_dedup_lane_first',
			'chat_codexbot_ts_dedup_lane',
			'om_codexbot_dedup_lane_same',
			'dedupe this inbound event across lanes'
		) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'
		assert first_resp.commands[0].stream_id != ''

		replay_resp := harness.dispatch_feishu_message(
			'codexbot_ts_dedup_lane_replay',
			'trace_codexbot_ts_dedup_lane_replay',
			'chat_codexbot_ts_dedup_lane',
			'om_codexbot_dedup_lane_same',
			'dedupe this inbound event across lanes'
		) or { panic(err) }
		assert replay_resp.handled
		assert replay_resp.commands.len == 0
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_dedupes_replayed_feishu_message_by_event_id() {
	codexbot_ts_with_harness_config('codexbot_ts_feishu_dedup_event_id.sqlite', 2, true, fn (mut harness CodexbotTsTestHarness) {
		first_resp := harness.dispatch_feishu_message_with_event(
			'codexbot_ts_dedup_event_first',
			'trace_codexbot_ts_dedup_event_first',
			'chat_codexbot_ts_dedup_event',
			'om_codexbot_dedup_event_first',
			'dedupe this inbound event by event id',
			'evt_codexbot_dedup_event',
			'1710000000'
		) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'
		assert first_resp.commands[0].stream_id != ''

		replay_resp := harness.dispatch_feishu_message_with_event(
			'codexbot_ts_dedup_event_replay',
			'trace_codexbot_ts_dedup_event_replay',
			'chat_codexbot_ts_dedup_event',
			'om_codexbot_dedup_event_second',
			'dedupe this inbound event by event id',
			'evt_codexbot_dedup_event',
			'1710000000'
		) or { panic(err) }
		assert replay_resp.handled
		assert replay_resp.commands.len == 0
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_scopes_sessions_by_feishu_thread_root() {
	codexbot_ts_with_harness('codexbot_ts_thread_scope.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		first_resp := harness.dispatch_feishu_thread_message(
			'codexbot_ts_thread_scope_first',
			'trace_codexbot_ts_thread_scope_first',
			'chat_codexbot_ts_thread_scope',
			'om_codexbot_thread_scope_first',
			'thread A task',
			'om_thread_root_A',
			'om_thread_parent_A'
		) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'
		assert first_resp.commands[0].method == 'thread/start'
		assert first_resp.commands[0].stream_id != ''

		second_resp := harness.dispatch_feishu_thread_message(
			'codexbot_ts_thread_scope_second',
			'trace_codexbot_ts_thread_scope_second',
			'chat_codexbot_ts_thread_scope',
			'om_codexbot_thread_scope_second',
			'thread B task',
			'om_thread_root_B',
			'om_thread_parent_B'
		) or { panic(err) }
		assert second_resp.handled
		assert second_resp.commands.len == 1
		assert second_resp.commands[0].type_ == 'provider.rpc.call'
		assert second_resp.commands[0].method == 'thread/start'
		assert second_resp.commands[0].stream_id != ''

		state_resp := harness.admin_state('trace_codexbot_ts_thread_scope_state',
			'req_codexbot_ts_thread_scope_state') or { panic(err) }
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
	codexbot_ts_with_harness('codexbot_ts_stale_busy.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		first_resp := harness.dispatch_feishu_message(
			'codexbot_ts_stale_busy_first',
			'trace_codexbot_ts_stale_busy_first',
			'chat_codexbot_ts_stale_busy',
			'om_codexbot_stale_busy_first',
			'first task goes stale'
		) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'
		time.sleep(5 * time.millisecond)

		second_resp := harness.dispatch_feishu_message(
			'codexbot_ts_stale_busy_second',
			'trace_codexbot_ts_stale_busy_second',
			'chat_codexbot_ts_stale_busy',
			'om_codexbot_stale_busy_second',
			'second task should proceed'
		) or { panic(err) }
		assert second_resp.handled
		assert second_resp.commands.len == 1
		assert second_resp.commands[0].type_ == 'provider.rpc.call'

		state_resp := harness.admin_state('trace_codexbot_ts_stale_busy_state',
			'req_codexbot_ts_stale_busy_state') or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"lastEvent":"stale.auto_detach"')
		assert state_resp.response.body.contains('second task should proceed')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_busy_guard_stays_within_same_feishu_thread() {
	codexbot_ts_with_harness('codexbot_ts_thread_busy_guard.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		first_resp := harness.dispatch_feishu_thread_message(
			'codexbot_ts_thread_busy_first',
			'trace_codexbot_ts_thread_busy_first',
			'chat_codexbot_ts_thread_busy',
			'om_codexbot_thread_busy_first',
			'thread busy first',
			'om_thread_busy_root',
			'om_thread_busy_parent'
		) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'

		second_resp := harness.dispatch_feishu_thread_message(
			'codexbot_ts_thread_busy_second',
			'trace_codexbot_ts_thread_busy_second',
			'chat_codexbot_ts_thread_busy',
			'om_codexbot_thread_busy_second',
			'thread busy second',
			'om_thread_busy_root',
			'om_thread_busy_parent_2'
		) or { panic(err) }
		assert second_resp.handled
		assert second_resp.commands.len == 1
		assert second_resp.commands[0].type_ == 'provider.message.send'
		assert second_resp.commands[0].target_type == 'message_id'
		assert second_resp.commands[0].target == 'om_codexbot_thread_busy_second'
		assert second_resp.commands[0].text.contains('Still working on the previous request in this thread.')
	})
}
