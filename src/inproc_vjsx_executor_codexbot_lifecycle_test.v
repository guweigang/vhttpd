module main

import net.http
import os

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_cancel_in_other_thread_does_not_touch_active_run() {
	codexbot_ts_with_harness('codexbot_ts_thread_cancel_isolated.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		first_resp := harness.dispatch_feishu_thread_message(
			'codexbot_ts_thread_cancel_active',
			'trace_codexbot_ts_thread_cancel_active',
			'chat_codexbot_ts_thread_cancel',
			'om_codexbot_thread_cancel_active',
			'active thread task',
			'om_thread_cancel_root_A',
			'om_thread_cancel_parent_A'
		) or { panic(err) }
		assert first_resp.handled
		assert first_resp.commands.len == 1
		assert first_resp.commands[0].type_ == 'provider.rpc.call'

		cancel_resp := harness.dispatch_feishu_thread_message(
			'codexbot_ts_thread_cancel_other',
			'trace_codexbot_ts_thread_cancel_other',
			'chat_codexbot_ts_thread_cancel',
			'om_codexbot_thread_cancel_other',
			'/cancel',
			'om_thread_cancel_root_B',
			'om_thread_cancel_parent_B'
		) or { panic(err) }
		assert cancel_resp.handled
		assert cancel_resp.commands.len == 1
		assert cancel_resp.commands[0].type_ == 'provider.message.send'
		assert cancel_resp.commands[0].target_type == 'message_id'
		assert cancel_resp.commands[0].target == 'om_codexbot_thread_cancel_other'
		assert cancel_resp.commands[0].text.contains('No active Codex run to cancel in this thread.')

		state_resp := harness.admin_state('trace_codexbot_ts_thread_cancel_state',
			'req_codexbot_ts_thread_cancel_state') or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"sessionKey":"chat_codexbot_ts_thread_cancel::thread:om_thread_cancel_root_A"')
		assert state_resp.response.body.contains('"status":"queued"')
		assert !state_resp.response.body.contains('"lastEvent":"user.cancel"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_cancel_detaches_active_stream() {
	codexbot_ts_with_harness('codexbot_ts_cancel.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_cancel_task',
			'trace_codexbot_ts_cancel_task',
			'chat_codexbot_ts_cancel',
			'om_codexbot_cancel_task',
			'cancel this run'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ := harness.dispatch_codex_event(
			'codexbot_ts_cancel_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_cancel_001"},"has_error":false}'
		) or { panic(err) }

		cancel_resp := harness.dispatch_feishu_message(
			'codexbot_ts_cancel_cmd',
			'trace_codexbot_ts_cancel_cmd',
			'chat_codexbot_ts_cancel',
			'om_codexbot_cancel_cmd',
			'/cancel'
		) or { panic(err) }
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

		state_resp := harness.admin_state('trace_codexbot_ts_cancel_state',
			'req_codexbot_ts_cancel_state') or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"status":"cancelled"')
		assert state_resp.response.body.contains('"lastEvent":"user.cancel"')
		assert state_resp.response.body.contains('"threadId":""')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_cancel_interrupts_active_turn_when_turn_id_exists() {
	codexbot_ts_with_harness('codexbot_ts_cancel_interrupt.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_cancel_interrupt_task',
			'trace_codexbot_ts_cancel_interrupt_task',
			'chat_codexbot_ts_cancel_interrupt',
			'om_codexbot_cancel_interrupt_task',
			'cancel this turn'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ := harness.dispatch_codex_event(
			'codexbot_ts_cancel_interrupt_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_cancel_interrupt_001"},"has_error":false}'
		) or { panic(err) }
		_ = harness.dispatch_codex_event(
			'codexbot_ts_cancel_interrupt_turn',
			stream_id,
			'codex.notification',
			'{"method":"turn/started","params":{"threadId":"thread_cancel_interrupt_001","turn":{"id":"turn_cancel_interrupt_001","items":[],"status":"in_progress","error":null}}}'
		) or { panic(err) }

		cancel_resp := harness.dispatch_feishu_message(
			'codexbot_ts_cancel_interrupt_cmd',
			'trace_codexbot_ts_cancel_interrupt_cmd',
			'chat_codexbot_ts_cancel_interrupt',
			'om_codexbot_cancel_interrupt_cmd',
			'/cancel'
		) or { panic(err) }
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

		state_resp := harness.admin_state('trace_codexbot_ts_cancel_interrupt_state',
			'req_codexbot_ts_cancel_interrupt_state') or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"status":"cancelled"')
		assert state_resp.response.body.contains('"turnId":"turn_cancel_interrupt_001"')
		assert state_resp.response.body.contains('"lastEvent":"user.cancel.interrupt"')
		assert state_resp.response.body.contains('"threadId":""')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_existing_thread_starts_turn_directly() {
	codexbot_ts_with_temp_db('codexbot_ts_existing_thread_turn.sqlite', fn (_ string) {
		mut executor := codexbot_ts_new_executor(true)
		defer {
			executor.close()
		}
		mut app := App{}
		first_task, first_stream_id := codexbot_ts_start_task(
			mut executor,
			mut app,
			'codexbot_ts_existing_thread_first',
			'trace_codexbot_ts_existing_thread_first',
			'chat_codexbot_ts_existing_thread',
			'om_codexbot_existing_thread_first',
			'first turn'
		) or { panic(err) }
		assert first_task.handled
		assert first_stream_id != ''

		first_rpc := codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_existing_thread_first_rpc',
			first_stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_existing_001"},"has_error":false}'
		) or { panic(err) }
		assert first_rpc.commands.len == 1
		assert first_rpc.commands[0].method == 'turn/start'
		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_existing_thread_turn_rpc',
			first_stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_existing_001"}},"has_error":false}'
		) or { panic(err) }
		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_existing_thread_completed',
			first_stream_id,
			'codex.notification',
			'{"method":"turn/completed","params":{}}'
		) or { panic(err) }
		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_existing_thread_read',
			first_stream_id,
			'codex.rpc.response',
			'{"method":"thread/read","result":{"thread":{"id":"thread_existing_001","turns":[{"id":"turn_thread_existing_001","items":[{"type":"agentMessage","id":"item_thread_existing_001","text":"first turn done","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		) or { panic(err) }

		second_task, _ := codexbot_ts_start_task(
			mut executor,
			mut app,
			'codexbot_ts_existing_thread_second',
			'trace_codexbot_ts_existing_thread_second',
			'chat_codexbot_ts_existing_thread',
			'om_codexbot_existing_thread_second',
			'second turn'
		) or { panic(err) }
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
		mut executor_a := codexbot_ts_new_executor(false)
		defer {
			executor_a.close()
		}
		mut app := App{}
		first_task, first_stream_id := codexbot_ts_start_task(
			mut executor_a,
			mut app,
			'codexbot_ts_reuse_task_1',
			'trace_codexbot_ts_reuse_task_1',
			'chat_codexbot_ts_reuse',
			'om_codexbot_reuse_task_1',
			'first task'
		) or { panic(err) }
		assert first_task.handled
		assert first_stream_id != ''
		_ = codexbot_ts_dispatch_codex_event(
			mut executor_a,
			mut app,
			'codexbot_ts_reuse_rpc_1',
			first_stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_reuse_001"},"has_error":false}'
		) or { panic(err) }
		_ = codexbot_ts_dispatch_codex_event(
			mut executor_a,
			mut app,
			'codexbot_ts_reuse_turn_rpc_1',
			first_stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_reuse_001"}},"has_error":false}'
		) or { panic(err) }
		_ = codexbot_ts_dispatch_codex_event(
			mut executor_a,
			mut app,
			'codexbot_ts_reuse_completed_1',
			first_stream_id,
			'codex.notification',
			'{"method":"turn/completed","params":{}}'
		) or { panic(err) }
		_ = codexbot_ts_dispatch_codex_event(
			mut executor_a,
			mut app,
			'codexbot_ts_reuse_read_1',
			first_stream_id,
			'codex.rpc.response',
			'{"method":"thread/read","result":{"thread":{"id":"thread_reuse_001","turns":[{"id":"turn_thread_reuse_001","items":[{"type":"agentMessage","id":"item_thread_reuse_001","text":"reuse ok","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		) or { panic(err) }

		mut executor_b := codexbot_ts_new_executor(false)
		defer {
			executor_b.close()
		}
		second_task, _ := codexbot_ts_start_task(
			mut executor_b,
			mut app,
			'codexbot_ts_reuse_task_2',
			'trace_codexbot_ts_reuse_task_2',
			'chat_codexbot_ts_reuse',
			'om_codexbot_reuse_task_2',
			'second task'
		) or { panic(err) }
		assert second_task.handled
		assert second_task.commands.len == 1
		assert second_task.commands[0].type_ == 'provider.rpc.call'
		assert second_task.commands[0].method == 'turn/start'
		assert second_task.commands[0].params.contains('"threadId":"thread_reuse_001"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_recovers_when_reused_thread_is_missing() {
	codexbot_ts_with_temp_db('codexbot_ts_recover_missing_thread.sqlite', fn (_ string) {
		mut executor := codexbot_ts_new_executor(false)
		defer {
			executor.close()
		}
		mut app := App{}
		first_task, first_stream_id := codexbot_ts_start_task(
			mut executor,
			mut app,
			'codexbot_ts_recover_missing_thread_task_1',
			'trace_codexbot_ts_recover_missing_thread_task_1',
			'chat_codexbot_ts_recover_missing_thread',
			'om_codexbot_recover_missing_thread_task_1',
			'first task'
		) or { panic(err) }
		assert first_task.handled
		assert first_stream_id != ''
		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_recover_missing_thread_rpc_1',
			first_stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_recover_missing_001"},"has_error":false}'
		) or { panic(err) }
		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_recover_missing_thread_turn_rpc_1',
			first_stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_recover_missing_001"}},"has_error":false}'
		) or { panic(err) }
		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_recover_missing_thread_completed_1',
			first_stream_id,
			'codex.notification',
			'{"method":"turn/completed","params":{}}'
		) or { panic(err) }
		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_recover_missing_thread_read_1',
			first_stream_id,
			'codex.rpc.response',
			'{"method":"thread/read","result":{"thread":{"id":"thread_recover_missing_001","turns":[{"id":"turn_thread_recover_missing_001","items":[{"type":"agentMessage","id":"item_thread_recover_missing_001","text":"recover me","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		) or { panic(err) }

		second_task, second_stream_id := codexbot_ts_start_task(
			mut executor,
			mut app,
			'codexbot_ts_recover_missing_thread_task_2',
			'trace_codexbot_ts_recover_missing_thread_task_2',
			'chat_codexbot_ts_recover_missing_thread',
			'om_codexbot_recover_missing_thread_task_2',
			'follow up task'
		) or { panic(err) }
		assert second_task.handled
		assert second_task.commands.len == 1
		assert second_task.commands[0].method == 'turn/start'
		assert second_task.commands[0].params.contains('"threadId":"thread_recover_missing_001"')
		assert second_stream_id != ''

		recover_resp := codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_recover_missing_thread_error',
			second_stream_id,
			'codex.rpc.response',
			'{"method":"codex.error_burst","result":["thread not found: thread_recover_missing_001"],"has_error":true}'
		) or { panic(err) }
		assert recover_resp.handled
		assert recover_resp.commands.len == 2
		assert recover_resp.commands[0].type_ == 'provider.message.send'
		assert recover_resp.commands[0].content.contains('**Thread Restarting**')
		assert recover_resp.commands[0].content.contains('thread_recover_missing_001')
		assert recover_resp.commands[1].type_ == 'provider.rpc.call'
		assert recover_resp.commands[1].method == 'thread/start'
		assert !recover_resp.commands[1].params.contains('"threadId":"thread_recover_missing_001"')

		restart_resp := codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_recover_missing_thread_restart_ok',
			second_stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_recover_missing_002"},"has_error":false}'
		) or { panic(err) }
		assert restart_resp.handled
		assert restart_resp.commands.len == 1
		assert restart_resp.commands[0].type_ == 'provider.rpc.call'
		assert restart_resp.commands[0].method == 'turn/start'
		assert restart_resp.commands[0].params.contains('"threadId":"thread_recover_missing_002"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_restores_stream_draft_after_restart() {
	codexbot_ts_with_temp_db('codexbot_ts_restore_draft.sqlite', fn (_ string) {
		mut executor_a := codexbot_ts_new_executor(false)
		defer {
			executor_a.close()
		}
		mut app := App{}
		task_resp, stream_id := codexbot_ts_start_task(
			mut executor_a,
			mut app,
			'codexbot_ts_restore_task_1',
			'trace_codexbot_ts_restore_task_1',
			'chat_codexbot_ts_restore',
			'om_codexbot_restore_task_1',
			'draft task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''
		first_delta := codexbot_ts_dispatch_codex_event(
			mut executor_a,
			mut app,
			'codexbot_ts_restore_delta_1',
			stream_id,
			'codex.notification',
			'{"method":"item/agentMessage/delta","params":{"delta":"hello "}}'
		) or { panic(err) }
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
		second_delta := codexbot_ts_dispatch_codex_event(
			mut executor_b,
			mut app,
			'codexbot_ts_restore_delta_2',
			stream_id,
			'codex.notification',
			'{"method":"item/agentMessage/delta","params":{"delta":"world"}}'
		) or { panic(err) }
		assert second_delta.handled
		assert second_delta.commands.len == 1
		assert second_delta.commands[0].type_ == 'stream.append'
		assert second_delta.commands[0].stream_id == item_stream_id
		assert second_delta.commands[0].text == 'world'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_persists_completed_stream_snapshot() {
	codexbot_ts_with_harness('codexbot_ts_completed_snapshot.sqlite', false, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_completed_task',
			'trace_codexbot_ts_completed_task',
			'chat_codexbot_ts_completed',
			'om_codexbot_completed_task',
			'finish task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ := harness.dispatch_codex_event(
			'codexbot_ts_completed_rpc',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_completed_001"},"has_error":false}'
		) or { panic(err) }

		_ := harness.dispatch_codex_event(
			'codexbot_ts_completed_delta_1',
			stream_id,
			'codex.notification',
			'{"method":"item/agentMessage/delta","params":{"delta":"hello "}}'
		) or { panic(err) }
		_ := harness.dispatch_codex_event(
			'codexbot_ts_completed_delta_2',
			stream_id,
			'codex.notification',
			'{"method":"item/agentMessage/delta","params":{"delta":"world"}}'
		) or { panic(err) }
		_ := harness.dispatch_codex_event(
			'codexbot_ts_completed_done',
			stream_id,
			'codex.notification',
			'{"method":"turn/completed","params":{}}'
		) or { panic(err) }

		outcome := harness.admin_state('trace_codexbot_ts_completed_state',
			'req_codexbot_ts_completed_state') or { panic(err) }
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
	codexbot_ts_with_harness('codexbot_ts_content_array.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_content_array_task',
			'trace_codexbot_ts_content_array_task',
			'chat_codexbot_ts_content_array',
			'om_codexbot_content_array_task',
			'content array task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''
		_ := harness.dispatch_codex_event(
			'codexbot_ts_content_array_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_content_array_001"},"has_error":false}'
		) or { panic(err) }
		message_resp := harness.dispatch_codex_event(
			'codexbot_ts_content_array_message',
			stream_id,
			'codex.notification',
			'{"method":"item/completed","params":{"item":{"content":[{"type":"output_text","text":"final answer from content array"}]}}}'
		) or { panic(err) }
		assert message_resp.handled
		assert message_resp.commands.len == 3
		assert message_resp.commands[0].type_ == 'provider.message.send'
		assert message_resp.commands[1].type_ == 'stream.append'
		assert message_resp.commands[1].text == 'final answer from content array'
		assert message_resp.commands[2].type_ == 'stream.finish'
		assert message_resp.commands[2].stream_id == message_resp.commands[1].stream_id
		idle_resp := harness.dispatch_codex_event(
			'codexbot_ts_content_array_idle',
			stream_id,
			'codex.notification',
			'{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
		) or { panic(err) }
		assert idle_resp.handled
		assert idle_resp.commands.len == 0
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_does_not_echo_user_message_item_completed() {
	codexbot_ts_with_harness('codexbot_ts_user_message_item_completed.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_user_message_item_task',
			'trace_codexbot_ts_user_message_item_task',
			'chat_codexbot_ts_user_message_item',
			'om_codexbot_user_message_item_task',
			'我刚才改了什么?'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''
		
		_ := harness.dispatch_codex_event(
			'codexbot_ts_user_message_item_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_user_message_item_001"},"has_error":false}'
		) or { panic(err) }

		user_item_resp := harness.dispatch_codex_event(
			'codexbot_ts_user_message_item_completed',
			stream_id,
			'codex.notification',
			'{"method":"item/completed","params":{"threadId":"thread_user_message_item_001","turnId":"turn_user_message_item_001","item":{"id":"item_user_message_item_001","type":"userMessage","content":[{"type":"text","text":"我刚才改了什么?","text_elements":[]}]}}}'
		) or { panic(err) }
		assert user_item_resp.handled
		assert user_item_resp.commands.len == 0

		assistant_item_resp := harness.dispatch_codex_event(
			'codexbot_ts_user_message_item_answer',
			stream_id,
			'codex.notification',
			'{"method":"item/completed","params":{"threadId":"thread_user_message_item_001","turnId":"turn_user_message_item_001","item":{"id":"item_user_message_item_002","type":"agentMessage","phase":"final_answer","text":"这是 assistant 的答案。"}}}'
		) or { panic(err) }
		assert assistant_item_resp.handled
		assert assistant_item_resp.commands.len == 3
		assert assistant_item_resp.commands[0].type_ == 'provider.message.send'
		assert assistant_item_resp.commands[1].type_ == 'stream.append'
		assert assistant_item_resp.commands[1].text == '这是 assistant 的答案。'
		assert assistant_item_resp.commands[2].type_ == 'stream.finish'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_turn_completed_falls_back_to_thread_read() {
	codexbot_ts_with_harness('codexbot_ts_turn_completed_thread_read.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_turn_completed_thread_read_task',
			'trace_codexbot_ts_turn_completed_thread_read_task',
			'chat_codexbot_ts_turn_completed_thread_read',
			'om_codexbot_turn_completed_thread_read_task',
			'hello'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ := harness.dispatch_codex_event(
			'codexbot_ts_turn_completed_thread_read_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_thread_read_001"},"has_error":false}'
		) or { panic(err) }

		_ := harness.dispatch_codex_event(
			'codexbot_ts_turn_completed_thread_read_turn',
			stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_thread_read_001"}},"has_error":false}'
		) or { panic(err) }

		completed_resp := harness.dispatch_codex_event(
			'codexbot_ts_turn_completed_thread_read_completed',
			stream_id,
			'codex.notification',
			'{"method":"turn/completed","params":{"threadId":"thread_thread_read_001","turn":{"id":"turn_thread_read_001","items":[],"status":"completed","error":null}}}'
		) or { panic(err) }
		assert completed_resp.handled
		assert completed_resp.commands.len == 0
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_turn_completed_prefers_final_message_from_turn_items() {
	codexbot_ts_with_harness('codexbot_ts_turn_completed_turn_items.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_turn_completed_turn_items_task',
			'trace_codexbot_ts_turn_completed_turn_items_task',
			'chat_codexbot_ts_turn_completed_turn_items',
			'om_codexbot_turn_completed_turn_items_task',
			'hello'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ := harness.dispatch_codex_event(
			'codexbot_ts_turn_completed_turn_items_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_turn_items_001"},"has_error":false}'
		) or { panic(err) }

		_ := harness.dispatch_codex_event(
			'codexbot_ts_turn_completed_turn_items_turn',
			stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_turn_items_001"}},"has_error":false}'
		) or { panic(err) }

		_ := harness.dispatch_codex_event(
			'codexbot_ts_turn_completed_turn_items_delta',
			stream_id,
			'codex.notification',
			'{"method":"item/agentMessage/delta","params":{"threadId":"thread_turn_items_001","turnId":"turn_turn_items_001","delta":"draft commentary"}}'
		) or { panic(err) }

		completed_resp := harness.dispatch_codex_event(
			'codexbot_ts_turn_completed_turn_items_completed',
			stream_id,
			'codex.notification',
			'{"method":"turn/completed","params":{"threadId":"thread_turn_items_001","turn":{"id":"turn_turn_items_001","items":[{"type":"agentMessage","id":"item_turn_items_001","phase":"commentary","text":"draft commentary"},{"type":"agentMessage","id":"item_turn_items_002","phase":"final_answer","text":"final answer from turn items"}],"status":"completed","error":null}}}'
		) or { panic(err) }
		assert completed_resp.handled
		assert completed_resp.commands.len >= 1

		state_resp := harness.admin_state('trace_codexbot_ts_turn_completed_turn_items_state',
			'req_codexbot_ts_turn_completed_turn_items_state') or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"status":"completed"')
		assert state_resp.response.body.contains('draft commentary')
		assert state_resp.response.body.contains('final answer from turn items')
		assert state_resp.response.body.contains('"lastEvent":"turn/completed"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_read_preserves_multiple_assistant_items() {
	codexbot_ts_with_harness('codexbot_ts_thread_read_multi_items.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_thread_read_multi_items_task',
			'trace_codexbot_ts_thread_read_multi_items_task',
			'chat_codexbot_ts_thread_read_multi_items',
			'om_codexbot_thread_read_multi_items_task',
			'我们到哪儿了？'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ := harness.dispatch_codex_event(
			'codexbot_ts_thread_read_multi_items_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_read_multi_items_001"},"has_error":false}'
		) or { panic(err) }

		_ := harness.dispatch_codex_event(
			'codexbot_ts_thread_read_multi_items_turn',
			stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_read_multi_items_001"}},"has_error":false}'
		) or { panic(err) }

		read_resp := harness.dispatch_codex_event(
			'codexbot_ts_thread_read_multi_items_read',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/read","result":{"thread":{"id":"thread_read_multi_items_001","turns":[{"id":"turn_read_multi_items_001","items":[{"type":"agentMessage","id":"item_read_multi_items_001","text":"第一条 item","phase":"commentary","memoryCitation":null},{"type":"agentMessage","id":"item_read_multi_items_002","text":"第二条 item","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 4
		assert read_resp.commands[0].type_ == 'provider.message.send'
		assert read_resp.commands[0].text == '第一条 item'
		assert read_resp.commands[1].type_ == 'stream.finish'
		assert read_resp.commands[2].type_ == 'provider.message.send'
		assert read_resp.commands[2].text == '第二条 item'
		assert read_resp.commands[3].type_ == 'stream.finish'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_read_recovers_missing_followup_item_stream() {
	codexbot_ts_with_harness('codexbot_ts_thread_read_missing_followup_item.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_thread_read_missing_followup_item_task',
			'trace_codexbot_ts_thread_read_missing_followup_item_task',
			'chat_codexbot_ts_thread_read_missing_followup_item',
			'om_codexbot_thread_read_missing_followup_item_task',
			'show progress in cards'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ := harness.dispatch_codex_event(
			'codexbot_ts_thread_read_missing_followup_item_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_read_missing_followup_item_001"},"has_error":false}'
		) or { panic(err) }

		_ := harness.dispatch_codex_event(
			'codexbot_ts_thread_read_missing_followup_item_turn',
			stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_read_missing_followup_item_001"}},"has_error":false}'
		) or { panic(err) }

		started_resp := harness.dispatch_codex_event(
			'codexbot_ts_thread_read_missing_followup_item_started',
			stream_id,
			'codex.notification',
			'{"method":"item/started","params":{"threadId":"thread_read_missing_followup_item_001","turnId":"turn_read_missing_followup_item_001","item":{"id":"item_read_missing_followup_item_001","type":"agentMessage","phase":"commentary"}}}'
		) or { panic(err) }
		assert started_resp.handled
		assert started_resp.commands.len == 1
		assert started_resp.commands[0].type_ == 'provider.message.send'
		commentary_item_stream_id := started_resp.commands[0].stream_id
		assert commentary_item_stream_id != ''
		assert commentary_item_stream_id != stream_id

		delta_resp := harness.dispatch_codex_event(
			'codexbot_ts_thread_read_missing_followup_item_delta',
			stream_id,
			'codex.notification',
			'{"method":"item/agentMessage/delta","params":{"threadId":"thread_read_missing_followup_item_001","turnId":"turn_read_missing_followup_item_001","itemId":"item_read_missing_followup_item_001","phase":"commentary","delta":"draft commentary"}}'
		) or { panic(err) }
		assert delta_resp.handled
		assert delta_resp.commands.len == 1
		assert delta_resp.commands[0].type_ == 'stream.append'
		assert delta_resp.commands[0].stream_id == commentary_item_stream_id
		assert delta_resp.commands[0].text == 'draft commentary'

		read_resp := harness.dispatch_codex_event(
			'codexbot_ts_thread_read_missing_followup_item_read',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/read","result":{"thread":{"id":"thread_read_missing_followup_item_001","turns":[{"id":"turn_read_missing_followup_item_001","items":[{"type":"agentMessage","id":"item_read_missing_followup_item_001","text":"draft commentary","phase":"commentary","memoryCitation":null},{"type":"agentMessage","id":"item_read_missing_followup_item_002","text":"final answer after reconnect","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 5
		assert read_resp.commands[0].type_ == 'stream.append'
		assert read_resp.commands[0].stream_id == stream_id
		assert read_resp.commands[0].text == '\n\nfinal answer after reconnect'
		assert read_resp.commands[1].type_ == 'stream.finish'
		assert read_resp.commands[1].stream_id == stream_id
		assert read_resp.commands[2].type_ == 'stream.finish'
		assert read_resp.commands[2].stream_id == commentary_item_stream_id
		assert read_resp.commands[3].type_ == 'provider.message.send'
		assert read_resp.commands[3].stream_id != stream_id
		assert read_resp.commands[3].stream_id != commentary_item_stream_id
		assert read_resp.commands[3].text == 'final answer after reconnect'
		assert read_resp.commands[4].type_ == 'stream.finish'
		assert read_resp.commands[4].stream_id == read_resp.commands[3].stream_id
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_persists_turn_id_from_delta_notification() {
	codexbot_ts_with_harness('codexbot_ts_turn_id_delta.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_turn_id_delta_task',
			'trace_codexbot_ts_turn_id_delta_task',
			'chat_codexbot_ts_turn_id_delta',
			'om_codexbot_turn_id_delta_task',
			'delta turn id task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ := harness.dispatch_codex_event(
			'codexbot_ts_turn_id_delta_notif',
			stream_id,
			'codex.notification',
			'{"method":"item/agentMessage/delta","params":{"threadId":"thread_turn_id_delta_001","turnId":"turn_turn_id_delta_001","itemId":"item_turn_id_delta_001","delta":"hello from turn id"}}'
		) or { panic(err) }

		state_resp := harness.admin_state('trace_codexbot_ts_turn_id_delta_state',
			'req_codexbot_ts_turn_id_delta_state') or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"turnId":"turn_turn_id_delta_001"')
		assert state_resp.response.body.contains('"threadId":"thread_turn_id_delta_001"')
		assert state_resp.response.body.contains('"draft":"hello from turn id"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_plain_prompt_item_started_opens_secondary_item_card_early() {
	codexbot_ts_with_harness('codexbot_ts_plain_prompt_item_early_card.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_plain_prompt_item_early_card_task',
			'trace_codexbot_ts_plain_prompt_item_early_card_task',
			'chat_codexbot_ts_plain_prompt_item_early_card',
			'om_codexbot_plain_prompt_item_early_card_task',
			'show progress in cards'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		started_resp := harness.dispatch_codex_event(
			'codexbot_ts_plain_prompt_item_early_card_started',
			stream_id,
			'codex.notification',
			'{"method":"item/started","params":{"threadId":"thread_plain_item_cards_001","turnId":"turn_plain_item_cards_001","item":{"id":"item_plain_item_cards_001","type":"agentMessage","phase":"commentary"}}}'
		) or { panic(err) }
		assert started_resp.handled
		assert started_resp.commands.len == 1
		assert started_resp.commands[0].type_ == 'provider.message.send'
		item_stream_id := started_resp.commands[0].stream_id
		assert item_stream_id != ''
		assert item_stream_id != stream_id

		delta_resp := harness.dispatch_codex_event(
			'codexbot_ts_plain_prompt_item_early_card_delta',
			stream_id,
			'codex.notification',
			'{"method":"item/agentMessage/delta","params":{"threadId":"thread_plain_item_cards_001","turnId":"turn_plain_item_cards_001","itemId":"item_plain_item_cards_001","delta":"第一段进展"}}'
		) or { panic(err) }
		assert delta_resp.handled
		assert delta_resp.commands.len == 1
		assert delta_resp.commands[0].type_ == 'stream.append'
		assert delta_resp.commands[0].stream_id == item_stream_id
		assert delta_resp.commands[0].text == '第一段进展'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_plain_prompt_non_assistant_item_started_does_not_open_secondary_card() {
	codexbot_ts_with_harness('codexbot_ts_plain_prompt_non_assistant_item_started.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_plain_prompt_non_assistant_item_started_task',
			'trace_codexbot_ts_plain_prompt_non_assistant_item_started_task',
			'chat_codexbot_ts_plain_prompt_non_assistant_item_started',
			'om_codexbot_plain_prompt_non_assistant_item_started_task',
			'show progress in cards'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		started_resp := harness.dispatch_codex_event(
			'codexbot_ts_plain_prompt_non_assistant_item_started_started',
			stream_id,
			'codex.notification',
			'{"method":"item/started","params":{"threadId":"thread_plain_non_assistant_item_cards_001","turnId":"turn_plain_non_assistant_item_cards_001","item":{"id":"item_plain_non_assistant_item_cards_001","type":"tool"}}}'
		) or { panic(err) }
		assert started_resp.handled
		assert started_resp.commands.len == 0
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_plain_prompt_non_assistant_item_delta_stays_on_parent_stream() {
	codexbot_ts_with_harness('codexbot_ts_plain_prompt_non_assistant_item_delta.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_plain_prompt_non_assistant_item_delta_task',
			'trace_codexbot_ts_plain_prompt_non_assistant_item_delta_task',
			'chat_codexbot_ts_plain_prompt_non_assistant_item_delta',
			'om_codexbot_plain_prompt_non_assistant_item_delta_task',
			'show progress in cards'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		started_resp := harness.dispatch_codex_event(
			'codexbot_ts_plain_prompt_non_assistant_item_delta_started',
			stream_id,
			'codex.notification',
			'{"method":"item/started","params":{"threadId":"thread_plain_non_assistant_item_delta_001","turnId":"turn_plain_non_assistant_item_delta_001","item":{"id":"item_plain_non_assistant_item_delta_001","type":"tool"}}}'
		) or { panic(err) }
		assert started_resp.handled
		assert started_resp.commands.len == 0

		delta_resp := harness.dispatch_codex_event(
			'codexbot_ts_plain_prompt_non_assistant_item_delta_delta',
			stream_id,
			'codex.notification',
			'{"method":"item/tool/delta","params":{"threadId":"thread_plain_non_assistant_item_delta_001","turnId":"turn_plain_non_assistant_item_delta_001","itemId":"item_plain_non_assistant_item_delta_001","delta":"tool progress"}}'
		) or { panic(err) }
		assert delta_resp.handled
		assert delta_resp.commands.len == 2
		assert delta_resp.commands[0].type_ == 'provider.message.send'
		assert delta_resp.commands[0].stream_id == stream_id
		assert delta_resp.commands[1].type_ == 'stream.append'
		assert delta_resp.commands[1].stream_id == stream_id
		assert delta_resp.commands[1].text == 'tool progress'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_plain_prompt_realtime_item_added_opens_item_stream_before_reasoning_delta() {
	codexbot_ts_with_harness('codexbot_ts_plain_prompt_realtime_item_added.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_plain_prompt_realtime_item_added_task',
			'trace_codexbot_ts_plain_prompt_realtime_item_added_task',
			'chat_codexbot_ts_plain_prompt_realtime_item_added',
			'om_codexbot_plain_prompt_realtime_item_added_task',
			'show progress in cards'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		added_resp := harness.dispatch_codex_event(
			'codexbot_ts_plain_prompt_realtime_item_added_added',
			stream_id,
			'codex.notification',
			'{"method":"thread/realtime/itemAdded","params":{"threadId":"thread_realtime_item_added_001","item":{"id":"item_realtime_item_added_001","type":"agentMessage","phase":"commentary","text":""}}}'
		) or { panic(err) }
		assert added_resp.handled
		assert added_resp.commands.len == 1
		assert added_resp.commands[0].type_ == 'provider.message.send'
		assert added_resp.commands[0].text.contains('处理中')
		assert added_resp.commands[0].text.trim_space() != ''
		item_stream_id := added_resp.commands[0].stream_id
		assert item_stream_id != ''
		assert item_stream_id != stream_id

		delta_resp := harness.dispatch_codex_event(
			'codexbot_ts_plain_prompt_realtime_item_added_reasoning_delta',
			stream_id,
			'codex.notification',
			'{"method":"item/reasoning/textDelta","params":{"threadId":"thread_realtime_item_added_001","turnId":"turn_realtime_item_added_001","itemId":"item_realtime_item_added_001","delta":"live reasoning text"}}'
		) or { panic(err) }
		assert delta_resp.handled
		assert delta_resp.commands.len == 1
		assert delta_resp.commands[0].type_ == 'stream.append'
		assert delta_resp.commands[0].stream_id == item_stream_id
		assert delta_resp.commands[0].text == 'live reasoning text'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_plain_prompt_realtime_reasoning_item_opens_item_stream_before_reasoning_delta() {
	codexbot_ts_with_harness('codexbot_ts_plain_prompt_realtime_reasoning_item.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_plain_prompt_realtime_reasoning_item_task',
			'trace_codexbot_ts_plain_prompt_realtime_reasoning_item_task',
			'chat_codexbot_ts_plain_prompt_realtime_reasoning_item',
			'om_codexbot_plain_prompt_realtime_reasoning_item_task',
			'show progress in cards'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		added_resp := harness.dispatch_codex_event(
			'codexbot_ts_plain_prompt_realtime_reasoning_item_added',
			stream_id,
			'codex.notification',
			'{"method":"thread/realtime/itemAdded","params":{"threadId":"thread_realtime_reasoning_item_001","item":{"id":"item_realtime_reasoning_item_001","type":"reasoning"}}}'
		) or { panic(err) }
		assert added_resp.handled
		assert added_resp.commands.len == 1
		assert added_resp.commands[0].type_ == 'provider.message.send'
		assert added_resp.commands[0].text.contains('思考中')
		assert added_resp.commands[0].text.trim_space() != ''
		item_stream_id := added_resp.commands[0].stream_id
		assert item_stream_id != ''
		assert item_stream_id != stream_id

		delta_resp := harness.dispatch_codex_event(
			'codexbot_ts_plain_prompt_realtime_reasoning_item_reasoning_delta',
			stream_id,
			'codex.notification',
			'{"method":"item/reasoning/textDelta","params":{"threadId":"thread_realtime_reasoning_item_001","turnId":"turn_realtime_reasoning_item_001","itemId":"item_realtime_reasoning_item_001","delta":"live reasoning text","contentIndex":0}}'
		) or { panic(err) }
		assert delta_resp.handled
		assert delta_resp.commands.len == 1
		assert delta_resp.commands[0].type_ == 'stream.append'
		assert delta_resp.commands[0].stream_id == item_stream_id
		assert delta_resp.commands[0].text == 'live reasoning text'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_plain_prompt_reasoning_summary_part_added_opens_item_stream_early() {
	codexbot_ts_with_harness('codexbot_ts_plain_prompt_reasoning_summary_part_added.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_plain_prompt_summary_part_added_task',
			'trace_codexbot_ts_plain_prompt_summary_part_added_task',
			'chat_codexbot_ts_plain_prompt_summary_part_added',
			'om_codexbot_plain_prompt_summary_part_added_task',
			'show reasoning summary in cards'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		added_resp := harness.dispatch_codex_event(
			'codexbot_ts_plain_prompt_summary_part_added_notif',
			stream_id,
			'codex.notification',
			'{"method":"item/reasoning/summaryPartAdded","params":{"threadId":"thread_summary_part_added_001","turnId":"turn_summary_part_added_001","itemId":"item_summary_part_added_001","summaryIndex":0}}'
		) or { panic(err) }
		assert added_resp.handled
		assert added_resp.commands.len == 1
		assert added_resp.commands[0].type_ == 'provider.message.send'
		assert added_resp.commands[0].text.contains('思考中')
		assert added_resp.commands[0].text.trim_space() != ''
		item_stream_id := added_resp.commands[0].stream_id
		assert item_stream_id != ''
		assert item_stream_id != stream_id

		delta_resp := harness.dispatch_codex_event(
			'codexbot_ts_plain_prompt_summary_text_delta',
			stream_id,
			'codex.notification',
			'{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"thread_summary_part_added_001","turnId":"turn_summary_part_added_001","itemId":"item_summary_part_added_001","delta":"summary text","summaryIndex":0}}'
		) or { panic(err) }
		assert delta_resp.handled
		assert delta_resp.commands.len == 1
		assert delta_resp.commands[0].type_ == 'stream.append'
		assert delta_resp.commands[0].stream_id == item_stream_id
		assert delta_resp.commands[0].text == 'summary text'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_raw_response_final_answer_completes_stream() {
	codexbot_ts_with_harness('codexbot_ts_raw_response_final.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_raw_response_final_task',
			'trace_codexbot_ts_raw_response_final_task',
			'chat_codexbot_ts_raw_response_final',
			'om_codexbot_raw_response_final_task',
			'raw response final task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		final_resp := harness.dispatch_codex_event(
			'codexbot_ts_raw_response_final_notif',
			stream_id,
			'codex.notification',
			'{"method":"rawResponseItem/completed","params":{"threadId":"thread_raw_final_001","turnId":"turn_raw_final_001","item":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"final answer from raw response"}]}}}'
		) or { panic(err) }
		assert final_resp.handled
		assert final_resp.commands.len == 3
		assert final_resp.commands[0].type_ == 'provider.message.send'
		assert final_resp.commands[1].type_ == 'stream.append'
		assert final_resp.commands[1].text == 'final answer from raw response'
		assert final_resp.commands[2].type_ == 'stream.finish'
		assert final_resp.commands[2].stream_id == final_resp.commands[1].stream_id

		state_resp := harness.admin_state('trace_codexbot_ts_raw_response_final_state',
			'req_codexbot_ts_raw_response_final_state') or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"turnId":"turn_raw_final_001"')
		assert state_resp.response.body.contains('"status":"completed"')
		assert state_resp.response.body.contains('"resultText":"final answer from raw response"')
		assert state_resp.response.body.contains('"lastEvent":"rawResponseItem/completed"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_commentary_after_final_answer_does_not_replace_parent_answer() {
	codexbot_ts_with_harness('codexbot_ts_commentary_after_final.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_commentary_after_final_task',
			'trace_codexbot_ts_commentary_after_final_task',
			'chat_codexbot_ts_commentary_after_final',
			'om_codexbot_commentary_after_final_task',
			'commentary after final task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		final_resp := harness.dispatch_codex_event(
			'codexbot_ts_commentary_after_final_final',
			stream_id,
			'codex.notification',
			'{"method":"item/completed","params":{"threadId":"thread_commentary_after_final_001","turnId":"turn_commentary_after_final_001","item":{"id":"item_commentary_after_final_001","type":"agentMessage","phase":"final_answer","text":"stable final answer"}}}'
		) or { panic(err) }
		assert final_resp.handled
		assert final_resp.commands.len == 3
		assert final_resp.commands[0].type_ == 'provider.message.send'
		assert final_resp.commands[1].type_ == 'stream.append'
		assert final_resp.commands[1].text == 'stable final answer'
		assert final_resp.commands[2].type_ == 'stream.finish'
		assert final_resp.commands[1].stream_id == stream_id

		commentary_resp := harness.dispatch_codex_event(
			'codexbot_ts_commentary_after_final_commentary',
			stream_id,
			'codex.notification',
			'{"method":"item/completed","params":{"threadId":"thread_commentary_after_final_001","turnId":"turn_commentary_after_final_001","item":{"id":"item_commentary_after_final_002","type":"agentMessage","phase":"commentary","text":"this commentary should not replace the answer"}}}'
		) or { panic(err) }
		assert commentary_resp.handled
		assert commentary_resp.commands.len == 0

		idle_resp := harness.dispatch_codex_event(
			'codexbot_ts_commentary_after_final_idle',
			stream_id,
			'codex.notification',
			'{"method":"thread/status/changed","params":{"threadId":"thread_commentary_after_final_001","status":{"type":"idle"}}}'
		) or { panic(err) }
		assert idle_resp.handled
		assert idle_resp.commands.len == 0

		state_resp := harness.admin_state('trace_codexbot_ts_commentary_after_final_state',
			'req_codexbot_ts_commentary_after_final_state') or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"resultText":"stable final answer"')
		assert !state_resp.response.body.contains('this commentary should not replace the answer')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_persists_thread_path_from_thread_start_response() {
	codexbot_ts_with_harness('codexbot_ts_idle_status.sqlite', false, fn (mut harness CodexbotTsTestHarness) {
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
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_idle_status_task',
			'trace_codexbot_ts_idle_status_task',
			'chat_codexbot_ts_idle_status',
			'om_codexbot_idle_status_task',
			'idle status task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ := harness.dispatch_codex_event(
			'codexbot_ts_idle_status_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_idle_001","thread":{"path":"' +
				session_file.replace('\\', '\\\\').replace('"', '\\"') + '"}},"has_error":false}'
		) or { panic(err) }
		_ := harness.dispatch_codex_event(
			'codexbot_ts_idle_status_turn',
			stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_idle_001"}},"has_error":false}'
		) or { panic(err) }
		state_resp := harness.admin_state('trace_codexbot_ts_idle_status_state',
			'req_codexbot_ts_idle_status_state') or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains(stream_id)
		assert state_resp.response.body.contains('thread_idle_001')
		assert state_resp.response.body.contains(session_file)
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_idle_status_resolves_session_from_thread_id() {
	codexbot_ts_with_harness('codexbot_ts_idle_status_lookup.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
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

		task_resp, stream_id := harness.start_task(
			'codexbot_ts_idle_status_lookup_task',
			'trace_codexbot_ts_idle_status_lookup_task',
			'chat_codexbot_ts_idle_status_lookup',
			'om_codexbot_idle_status_lookup_task',
			'idle status lookup task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ := harness.dispatch_codex_event(
			'codexbot_ts_idle_status_lookup_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"' + thread_id + '"},"has_error":false}'
		) or { panic(err) }
		_ := harness.dispatch_codex_event(
			'codexbot_ts_idle_status_lookup_turn',
			stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_idle_lookup_001"}},"has_error":false}'
		) or { panic(err) }
		idle_resp := harness.dispatch_codex_event(
			'codexbot_ts_idle_status_lookup_idle',
			stream_id,
			'codex.notification',
			'{"method":"thread/status/changed","params":{"status":{"type":"idle"}}}'
		) or { panic(err) }
		assert idle_resp.handled
		assert idle_resp.commands.len == 3
		assert idle_resp.commands[0].type_ == 'provider.message.send'
		assert idle_resp.commands[1].type_ == 'stream.append'
		assert idle_resp.commands[1].text == 'final answer from session lookup'
		assert idle_resp.commands[2].type_ == 'stream.finish'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_idle_status_after_commentary_still_reads_thread_final() {
	codexbot_ts_with_harness('codexbot_ts_idle_status_commentary.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_idle_status_commentary_task',
			'trace_codexbot_ts_idle_status_commentary_task',
			'chat_codexbot_ts_idle_status_commentary',
			'om_codexbot_idle_status_commentary_task',
			'summarize current progress'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ := harness.dispatch_codex_event(
			'codexbot_ts_idle_status_commentary_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_idle_commentary_001"},"has_error":false}'
		) or { panic(err) }
		_ := harness.dispatch_codex_event(
			'codexbot_ts_idle_status_commentary_turn',
			stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_idle_commentary_001"}},"has_error":false}'
		) or { panic(err) }
		commentary_resp := harness.dispatch_codex_event(
			'codexbot_ts_idle_status_commentary_item',
			stream_id,
			'codex.notification',
			'{"method":"item/completed","params":{"threadId":"thread_idle_commentary_001","turnId":"turn_idle_commentary_001","item":{"id":"item_idle_commentary_001","type":"agentMessage","phase":"commentary","text":"commentary only so far"}}}'
		) or { panic(err) }
		assert commentary_resp.handled

		idle_resp := harness.dispatch_codex_event(
			'codexbot_ts_idle_status_commentary_idle',
			stream_id,
			'codex.notification',
			'{"method":"thread/status/changed","params":{"threadId":"thread_idle_commentary_001","status":{"type":"idle"}}}'
		) or { panic(err) }
		assert idle_resp.handled
		assert idle_resp.commands.len == 1
		assert idle_resp.commands[0].type_ == 'provider.rpc.call'
		assert idle_resp.commands[0].method == 'thread/read'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_idle_status_prefers_richer_session_answer_over_partial_thread_read() {
	codexbot_ts_with_harness('codexbot_ts_idle_status_partial_thread_read.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
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

		task_resp, stream_id := harness.start_task(
			'codexbot_ts_idle_status_partial_thread_read_task',
			'trace_codexbot_ts_idle_status_partial_thread_read_task',
			'chat_codexbot_ts_idle_status_partial_thread_read',
			'om_codexbot_idle_status_partial_thread_read_task',
			'where are we now?'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ = harness.dispatch_codex_event(
			'codexbot_ts_idle_status_partial_thread_read_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_idle_partial_001","thread":{"path":"' +
			session_file.replace('\\', '\\\\').replace('"', '\\"') + '"}},"has_error":false}'
		) or { panic(err) }
		_ = harness.dispatch_codex_event(
			'codexbot_ts_idle_status_partial_thread_read_turn',
			stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_idle_partial_001"}},"has_error":false}'
		) or { panic(err) }
		partial_read_resp := harness.dispatch_codex_event(
			'codexbot_ts_idle_status_partial_thread_read_read',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/read","result":{"thread":{"id":"thread_idle_partial_001","turns":[{"id":"turn_idle_partial_001","items":[{"type":"agentMessage","id":"item_idle_partial_001","text":"第一段。","phase":"commentary","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		) or { panic(err) }
		assert partial_read_resp.handled
		assert partial_read_resp.commands.len == 2
		assert partial_read_resp.commands[0].type_ == 'provider.message.send'
		assert partial_read_resp.commands[0].text == '第一段。'
		assert partial_read_resp.commands[1].type_ == 'stream.finish'

		idle_resp := harness.dispatch_codex_event(
			'codexbot_ts_idle_status_partial_thread_read_idle',
			stream_id,
			'codex.notification',
			'{"method":"thread/status/changed","params":{"threadId":"thread_idle_partial_001","status":{"type":"idle"}}}'
		) or { panic(err) }
		assert idle_resp.handled
		assert idle_resp.commands.len == 2
		assert idle_resp.commands[0].type_ == 'stream.append'
		assert idle_resp.commands[0].text == '\n\n第二段。\n\n第三段。'
		assert idle_resp.commands[1].type_ == 'stream.finish'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_idle_status_uses_current_turn_session_answer_only() {
	codexbot_ts_with_harness('codexbot_ts_idle_status_current_turn_only.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
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

		task_resp, stream_id := harness.start_task(
			'codexbot_ts_idle_status_turn_filtered_task',
			'trace_codexbot_ts_idle_status_turn_filtered_task',
			'chat_codexbot_ts_idle_status_turn_filtered',
			'om_codexbot_idle_status_turn_filtered_task',
			'我们到哪儿了？'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ = harness.dispatch_codex_event(
			'codexbot_ts_idle_status_turn_filtered_thread',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_idle_turn_filtered_001","thread":{"path":"' +
			session_file.replace('\\', '\\\\').replace('"', '\\"') + '"}},"has_error":false}'
		) or { panic(err) }
		_ = harness.dispatch_codex_event(
			'codexbot_ts_idle_status_turn_filtered_turn',
			stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_idle_current_001"}},"has_error":false}'
		) or { panic(err) }
		idle_resp := harness.dispatch_codex_event(
			'codexbot_ts_idle_status_turn_filtered_idle',
			stream_id,
			'codex.notification',
			'{"method":"thread/status/changed","params":{"threadId":"thread_idle_turn_filtered_001","turnId":"turn_idle_current_001","status":{"type":"idle"}}}'
		) or { panic(err) }
		assert idle_resp.handled
		assert idle_resp.commands.len == 3
		assert idle_resp.commands[0].type_ == 'provider.message.send'
		assert idle_resp.commands[1].type_ == 'stream.append'
		assert idle_resp.commands[1].text == '当前这一轮的新答案'
		assert idle_resp.commands[2].type_ == 'stream.finish'

		state_resp := harness.admin_state('trace_codexbot_ts_idle_status_turn_filtered_state',
			'req_codexbot_ts_idle_status_turn_filtered_state') or { panic(err) }
		assert state_resp.response.status == 200
		assert state_resp.response.body.contains('"streamId":"' + stream_id + '"')
		assert state_resp.response.body.contains('"resultText":"当前这一轮的新答案"')
		assert !state_resp.response.body.contains('"resultText":"上一轮最后一条"')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_persists_error_stream_snapshot() {
	codexbot_ts_with_harness('codexbot_ts_error_snapshot.sqlite', false, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_error_task',
			'trace_codexbot_ts_error_task',
			'chat_codexbot_ts_error',
			'om_codexbot_error_task',
			'broken task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		error_resp := harness.dispatch_codex_event(
			'codexbot_ts_error_rpc',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{},"has_error":true}'
		) or { panic(err) }
		assert error_resp.handled
		assert error_resp.commands.len == 1
		assert error_resp.commands[0].content.contains('**Codex RPC Error**')
		assert error_resp.commands[0].content.contains('Method: `thread/start`')

		outcome := harness.admin_state('trace_codexbot_ts_error_state',
			'req_codexbot_ts_error_state') or { panic(err) }
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
	codexbot_ts_with_harness('codexbot_ts_error_burst.sqlite', false, fn (mut harness CodexbotTsTestHarness) {
		task_resp, stream_id := harness.start_task(
			'codexbot_ts_error_burst_task',
			'trace_codexbot_ts_error_burst_task',
			'chat_codexbot_ts_error_burst',
			'om_codexbot_error_burst_task',
			'burst task'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		error_resp := harness.dispatch_codex_event(
			'codexbot_ts_error_burst_rpc',
			stream_id,
			'codex.rpc.response',
			'{"method":"codex.error_burst","result":["{\\"method\\":\\"thread/status/changed\\",\\"params\\":{\\"threadId\\":\\"thread_error_burst_001\\",\\"status\\":{\\"type\\":\\"systemError\\"}}}"],"has_error":true}'
		) or { panic(err) }
		assert error_resp.handled
		assert error_resp.commands.len == 1
		assert error_resp.commands[0].type_ == 'provider.message.send'
		assert error_resp.commands[0].content.contains('**Codex RPC Error**')
		assert error_resp.commands[0].content.contains('Method: `codex.error_burst`')
		assert error_resp.commands[0].content.contains('systemError')
	})
}
