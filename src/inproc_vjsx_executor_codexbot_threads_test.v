module main

import os

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_command_reports_thread_scoped_session() {
	codexbot_ts_with_harness('codexbot_ts_thread_scope_command.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		task_resp := harness.dispatch_feishu_thread_message(
			'codexbot_ts_thread_scope_cmd_task',
			'trace_codexbot_ts_thread_scope_cmd_task',
			'chat_codexbot_ts_thread_scope_cmd',
			'om_codexbot_thread_scope_cmd_task',
			'thread scoped task',
			'om_thread_scope_cmd_root',
			'om_thread_scope_cmd_parent'
		) or { panic(err) }
		stream_id := codexbot_ts_first_stream_id(task_resp.commands)
		assert stream_id != ''

		_ = harness.dispatch_codex_event(
			'codexbot_ts_thread_scope_cmd_rpc',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_scope_cmd_001"},"has_error":false}'
		) or { panic(err) }

		thread_resp := harness.dispatch_feishu_thread_message(
			'codexbot_ts_thread_scope_cmd_query',
			'trace_codexbot_ts_thread_scope_cmd_query',
			'chat_codexbot_ts_thread_scope_cmd',
			'om_codexbot_thread_scope_cmd_query',
			'/thread',
			'om_thread_scope_cmd_root',
			'om_thread_scope_cmd_parent_2'
		) or { panic(err) }
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
	codexbot_ts_with_harness('codexbot_ts_threads_list.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		first_task, first_stream_id := harness.start_task(
			'codexbot_ts_threads_list_task_1',
			'trace_codexbot_ts_threads_list_task_1',
			'chat_codexbot_ts_threads_list',
			'om_codexbot_threads_list_task_1',
			'inspect bug one'
		) or { panic(err) }
		assert first_task.handled
		assert first_stream_id != ''
		_ = harness.dispatch_codex_event(
			'codexbot_ts_threads_list_rpc_1',
			first_stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_list_001"},"has_error":false}'
		) or { panic(err) }
		_ = harness.dispatch_codex_event(
			'codexbot_ts_threads_list_done_1',
			first_stream_id,
			'codex.notification',
			'{"method":"turn/completed","params":{}}'
		) or { panic(err) }
		_ = harness.dispatch_codex_event(
			'codexbot_ts_threads_list_read_1',
			first_stream_id,
			'codex.rpc.response',
			'{"method":"thread/read","result":{"thread":{"id":"thread_list_001","turns":[{"id":"turn_thread_list_001","items":[{"type":"agentMessage","id":"item_thread_list_001","text":"answer one","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		) or { panic(err) }

		second_task := harness.dispatch_feishu_message(
			'codexbot_ts_threads_list_task_2',
			'trace_codexbot_ts_threads_list_task_2',
			'chat_codexbot_ts_threads_list',
			'om_codexbot_threads_list_task_2',
			'/new'
		) or { panic(err) }
		assert second_task.commands.len == 1

		third_task, second_stream_id := harness.start_task(
			'codexbot_ts_threads_list_task_3',
			'trace_codexbot_ts_threads_list_task_3',
			'chat_codexbot_ts_threads_list',
			'om_codexbot_threads_list_task_3',
			'inspect bug two'
		) or { panic(err) }
		assert third_task.handled
		assert second_stream_id != ''
		_ = harness.dispatch_codex_event(
			'codexbot_ts_threads_list_rpc_2',
			second_stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_list_002"},"has_error":false}'
		) or { panic(err) }
		_ = harness.dispatch_codex_event(
			'codexbot_ts_threads_list_done_2',
			second_stream_id,
			'codex.notification',
			'{"method":"turn/completed","params":{}}'
		) or { panic(err) }
		_ = harness.dispatch_codex_event(
			'codexbot_ts_threads_list_read_2',
			second_stream_id,
			'codex.rpc.response',
			'{"method":"thread/read","result":{"thread":{"id":"thread_list_002","turns":[{"id":"turn_thread_list_002","items":[{"type":"agentMessage","id":"item_thread_list_002","text":"answer two","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		) or { panic(err) }

		threads_resp := harness.dispatch_feishu_message(
			'codexbot_ts_threads_list_query',
			'trace_codexbot_ts_threads_list_query',
			'chat_codexbot_ts_threads_list',
			'om_codexbot_threads_list_query',
			'/threads'
		) or { panic(err) }
		assert threads_resp.handled
		assert threads_resp.commands.len == 1
		assert threads_resp.commands[0].text.contains('**Recent Threads**')
		assert threads_resp.commands[0].text.contains('thread_list_001')
		assert threads_resp.commands[0].text.contains('thread_list_002')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_command_stays_within_selected_project() {
	codexbot_ts_with_harness('codexbot_ts_thread_project_scope.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		alpha_root := os.join_path(os.temp_dir(), 'codexbot_ts_thread_scope_alpha')
		beta_root := os.join_path(os.temp_dir(), 'codexbot_ts_thread_scope_beta')
		os.mkdir_all(alpha_root) or { panic(err) }
		os.mkdir_all(beta_root) or { panic(err) }

		alpha_bind := harness.dispatch_feishu_message(
			'codexbot_ts_thread_scope_alpha_bind',
			'trace_codexbot_ts_thread_scope_alpha_bind',
			'chat_codexbot_ts_thread_scope_project',
			'om_codexbot_ts_thread_scope_alpha_bind',
			'/bind alpha ' + alpha_root
		) or { panic(err) }
		assert alpha_bind.handled

		alpha_switch := harness.dispatch_feishu_message(
			'codexbot_ts_thread_scope_alpha_switch',
			'trace_codexbot_ts_thread_scope_alpha_switch',
			'chat_codexbot_ts_thread_scope_project',
			'om_codexbot_ts_thread_scope_alpha_switch',
			'/project alpha'
		) or { panic(err) }
		assert alpha_switch.handled

		alpha_task, alpha_stream_id := harness.start_task(
			'codexbot_ts_thread_scope_alpha_task',
			'trace_codexbot_ts_thread_scope_alpha_task',
			'chat_codexbot_ts_thread_scope_project',
			'om_codexbot_ts_thread_scope_alpha_task',
			'alpha task body'
		) or { panic(err) }
		assert alpha_task.handled
		assert alpha_stream_id != ''
		_ = harness.dispatch_codex_event(
			'codexbot_ts_thread_scope_alpha_rpc',
			alpha_stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_scope_shared"},"has_error":false}'
		) or { panic(err) }
		_ = harness.dispatch_codex_event(
			'codexbot_ts_thread_scope_alpha_done',
			alpha_stream_id,
			'codex.notification',
			'{"method":"turn/completed","params":{}}'
		) or { panic(err) }
		_ = harness.dispatch_codex_event(
			'codexbot_ts_thread_scope_alpha_read',
			alpha_stream_id,
			'codex.rpc.response',
			'{"method":"thread/read","result":{"thread":{"id":"thread_scope_shared","turns":[{"id":"turn_thread_scope_shared","items":[{"type":"agentMessage","id":"item_thread_scope_shared","text":"alpha answer","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		) or { panic(err) }

		beta_bind := harness.dispatch_feishu_message(
			'codexbot_ts_thread_scope_beta_bind',
			'trace_codexbot_ts_thread_scope_beta_bind',
			'chat_codexbot_ts_thread_scope_project',
			'om_codexbot_ts_thread_scope_beta_bind',
			'/bind beta ' + beta_root
		) or { panic(err) }
		assert beta_bind.handled

		projects_resp := harness.dispatch_feishu_message(
			'codexbot_ts_thread_scope_projects',
			'trace_codexbot_ts_thread_scope_projects',
			'chat_codexbot_ts_thread_scope_project',
			'om_codexbot_ts_thread_scope_projects',
			'/projects'
		) or { panic(err) }
		assert projects_resp.handled

		use_beta := harness.dispatch_feishu_message(
			'codexbot_ts_thread_scope_use_beta',
			'trace_codexbot_ts_thread_scope_use_beta',
			'chat_codexbot_ts_thread_scope_project',
			'om_codexbot_ts_thread_scope_use_beta',
			'/use beta'
		) or { panic(err) }
		assert use_beta.handled
		assert use_beta.commands[0].text.contains('Project: `beta`')

		thread_after_switch := harness.dispatch_feishu_message(
			'codexbot_ts_thread_scope_after_switch',
			'trace_codexbot_ts_thread_scope_after_switch',
			'chat_codexbot_ts_thread_scope_project',
			'om_codexbot_ts_thread_scope_after_switch',
			'/thread'
		) or { panic(err) }
		assert thread_after_switch.handled
		assert thread_after_switch.commands[0].text.contains('No thread is currently bound.')
		assert !thread_after_switch.commands[0].text.contains(alpha_stream_id)
		assert !thread_after_switch.commands[0].text.contains('alpha task body')
		assert !thread_after_switch.commands[0].text.contains('thread_scope_shared')

		beta_task, beta_stream_id := harness.start_task(
			'codexbot_ts_thread_scope_beta_task',
			'trace_codexbot_ts_thread_scope_beta_task',
			'chat_codexbot_ts_thread_scope_project',
			'om_codexbot_ts_thread_scope_beta_task',
			'beta task body'
		) or { panic(err) }
		assert beta_task.handled
		assert beta_stream_id != ''
		_ = harness.dispatch_codex_event(
			'codexbot_ts_thread_scope_beta_rpc',
			beta_stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_scope_shared"},"has_error":false}'
		) or { panic(err) }
		_ = harness.dispatch_codex_event(
			'codexbot_ts_thread_scope_beta_done',
			beta_stream_id,
			'codex.notification',
			'{"method":"turn/completed","params":{}}'
		) or { panic(err) }

		thread_selected := harness.dispatch_feishu_message(
			'codexbot_ts_thread_scope_select_shared',
			'trace_codexbot_ts_thread_scope_select_shared',
			'chat_codexbot_ts_thread_scope_project',
			'om_codexbot_ts_thread_scope_select_shared',
			'/thread thread_scope_shared'
		) or { panic(err) }
		assert thread_selected.handled
		assert thread_selected.commands[0].text.contains('Thread: `thread_scope_shared`')
		assert thread_selected.commands[0].text.contains('Latest Prompt: beta task body')
		assert thread_selected.commands[0].text.contains('Recent Interactions:')
		assert thread_selected.commands[0].text.contains(beta_stream_id)
		assert thread_selected.commands[0].text.contains('Prompt: beta task body')
		assert !thread_selected.commands[0].text.contains(alpha_stream_id)
		assert !thread_selected.commands[0].text.contains('Prompt: alpha task body')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_use_latest_and_thread_switch_reuse_selected_thread() {
	codexbot_ts_with_harness('codexbot_ts_use_latest.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		first_task, first_stream_id := harness.start_task(
			'codexbot_ts_use_latest_task_1',
			'trace_codexbot_ts_use_latest_task_1',
			'chat_codexbot_ts_use_latest',
			'om_codexbot_use_latest_task_1',
			'first thread seed'
		) or { panic(err) }
		assert first_task.handled
		assert first_stream_id != ''
		_ = harness.dispatch_codex_event(
			'codexbot_ts_use_latest_rpc_1',
			first_stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_use_latest_001"},"has_error":false}'
		) or { panic(err) }
		_ = harness.dispatch_codex_event(
			'codexbot_ts_use_latest_done_1',
			first_stream_id,
			'codex.notification',
			'{"method":"turn/completed","params":{}}'
		) or { panic(err) }

		_ = harness.dispatch_feishu_message(
			'codexbot_ts_use_latest_new',
			'trace_codexbot_ts_use_latest_new',
			'chat_codexbot_ts_use_latest',
			'om_codexbot_use_latest_new',
			'/new'
		) or { panic(err) }

		use_resp := harness.dispatch_feishu_message(
			'codexbot_ts_use_latest_cmd',
			'trace_codexbot_ts_use_latest_cmd',
			'chat_codexbot_ts_use_latest',
			'om_codexbot_use_latest_cmd',
			'/use latest'
		) or { panic(err) }
		assert use_resp.handled
		assert use_resp.commands.len == 2
		assert use_resp.commands[0].text.contains('thread_use_latest_001')
		assert use_resp.commands[0].text.contains('Reading the latest assistant reply from this thread.')
		assert use_resp.commands[1].type_ == 'provider.rpc.call'
		assert use_resp.commands[1].method == 'thread/read'
		assert use_resp.commands[1].params.contains('"threadId":"thread_use_latest_001"')
		assert use_resp.commands[1].params.contains('"includeTurns":true')
		use_stream_id := codexbot_ts_first_stream_id(use_resp.commands)
		assert use_stream_id != ''

		read_resp := harness.dispatch_codex_event(
			'codexbot_ts_use_latest_read_rpc',
			use_stream_id,
			'codex.rpc.response',
			'{"method":"thread/read","result":{"thread":{"id":"thread_use_latest_001","turns":[{"id":"turn_thread_use_latest_001","items":[{"type":"agentMessage","id":"item_thread_use_latest_001","text":"hello from latest thread","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 1
		assert read_resp.commands[0].type_ == 'provider.message.update'
		assert read_resp.commands[0].content.contains('hello from latest thread')

		second_task, _ := harness.start_task(
			'codexbot_ts_use_latest_task_2',
			'trace_codexbot_ts_use_latest_task_2',
			'chat_codexbot_ts_use_latest',
			'om_codexbot_use_latest_task_2',
			'continue latest'
		) or { panic(err) }
		assert second_task.handled
		assert second_task.commands.len == 1
		assert second_task.commands[0].type_ == 'provider.rpc.call'
		assert second_task.commands[0].method == 'turn/start'
		assert second_task.commands[0].params.contains('"threadId":"thread_use_latest_001"')

		thread_switch_resp := harness.dispatch_feishu_message(
			'codexbot_ts_thread_switch_cmd',
			'trace_codexbot_ts_thread_switch_cmd',
			'chat_codexbot_ts_use_latest',
			'om_codexbot_thread_switch_cmd',
			'/thread thread_use_latest_001'
		) or { panic(err) }
		assert thread_switch_resp.handled
		assert thread_switch_resp.commands.len == 1
		assert thread_switch_resp.commands[0].text.contains('**Thread Selected**')
		assert thread_switch_resp.commands[0].text.contains('Thread: `thread_use_latest_001`')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_rename_command() {
	codexbot_ts_with_harness('codexbot_ts_thread_rename.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		first_task, first_stream_id := harness.start_task(
			'codexbot_ts_thread_rename_seed',
			'trace_codexbot_ts_thread_rename_seed',
			'chat_codexbot_ts_thread_rename',
			'om_codexbot_thread_rename_seed',
			'seed thread for rename'
		) or { panic(err) }
		assert first_task.handled
		assert first_stream_id != ''
		_ = harness.dispatch_codex_event(
			'codexbot_ts_thread_rename_seed_rpc',
			first_stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_rename_001"},"has_error":false}'
		) or { panic(err) }

		rename_resp := harness.dispatch_feishu_message(
			'codexbot_ts_thread_rename_cmd',
			'trace_codexbot_ts_thread_rename_cmd',
			'chat_codexbot_ts_thread_rename',
			'om_codexbot_thread_rename_cmd',
			'/thread rename Stable Name'
		) or { panic(err) }
		assert rename_resp.handled
		assert rename_resp.commands.len == 2
		assert rename_resp.commands[0].text.contains('**Thread Rename**')
		assert rename_resp.commands[0].text.contains('Stable Name')
		assert rename_resp.commands[1].type_ == 'provider.rpc.call'
		assert rename_resp.commands[1].method == 'thread/name/set'
		assert rename_resp.commands[1].params.contains('"threadId":"thread_rename_001"')
		assert rename_resp.commands[1].params.contains('"name":"Stable Name"')
		rename_stream_id := codexbot_ts_first_stream_id(rename_resp.commands)
		assert rename_stream_id != ''

		thread_resp_pending := harness.dispatch_feishu_message(
			'codexbot_ts_thread_rename_thread_view_pending',
			'trace_codexbot_ts_thread_rename_thread_view_pending',
			'chat_codexbot_ts_thread_rename',
			'om_codexbot_thread_rename_thread_view_pending',
			'/thread'
		) or { panic(err) }
		assert thread_resp_pending.handled
		assert thread_resp_pending.commands.len == 1
		assert thread_resp_pending.commands[0].text.contains('Stable Name')

		rename_done := harness.dispatch_codex_event(
			'codexbot_ts_thread_rename_done',
			rename_stream_id,
			'codex.rpc.response',
			'{"method":"thread/name/set","result":{"thread":{"id":"thread_rename_001","name":"Stable Name"}},"has_error":false}'
		) or { panic(err) }
		assert rename_done.handled
		assert rename_done.commands.len == 1
		assert rename_done.commands[0].type_ == 'provider.message.update'
		assert rename_done.commands[0].content.contains('**Thread Renamed**')
		assert rename_done.commands[0].content.contains('Stable Name')

		thread_resp := harness.dispatch_feishu_message(
			'codexbot_ts_thread_rename_thread_view',
			'trace_codexbot_ts_thread_rename_thread_view',
			'chat_codexbot_ts_thread_rename',
			'om_codexbot_thread_rename_thread_view',
			'/thread'
		) or { panic(err) }
		assert thread_resp.handled
		assert thread_resp.commands.len == 1
		assert thread_resp.commands[0].text.contains('Stable Name')

		threads_resp := harness.dispatch_feishu_message(
			'codexbot_ts_thread_rename_threads_view',
			'trace_codexbot_ts_thread_rename_threads_view',
			'chat_codexbot_ts_thread_rename',
			'om_codexbot_thread_rename_threads_view',
			'/threads'
		) or { panic(err) }
		assert threads_resp.handled
		assert threads_resp.commands.len == 1
		assert threads_resp.commands[0].text.contains('Stable Name')
	})
}
