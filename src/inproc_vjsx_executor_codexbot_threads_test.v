module main

import os

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
		stream_id := codexbot_ts_first_stream_id(task_resp.commands)
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
		first_stream_id := codexbot_ts_first_stream_id(first_task.commands)
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
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_threads_list_read_1'
			provider:   'codex'
			instance:   'main'
			trace_id:   first_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_list_001","turns":[{"id":"turn_thread_list_001","items":[{"type":"agentMessage","id":"item_thread_list_001","text":"answer one","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
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
		second_stream_id := codexbot_ts_first_stream_id(third_task.commands)
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
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_threads_list_read_2'
			provider:   'codex'
			instance:   'main'
			trace_id:   second_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_list_002","turns":[{"id":"turn_thread_list_002","items":[{"type":"agentMessage","id":"item_thread_list_002","text":"answer two","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
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

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_command_stays_within_selected_project() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_project_scope.sqlite', fn (_ string) {
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
		alpha_root := os.join_path(os.temp_dir(), 'codexbot_ts_thread_scope_alpha')
		beta_root := os.join_path(os.temp_dir(), 'codexbot_ts_thread_scope_beta')
		os.mkdir_all(alpha_root) or { panic(err) }
		os.mkdir_all(beta_root) or { panic(err) }

		alpha_bind := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_scope_alpha_bind'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_scope_alpha_bind'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_scope_alpha_bind'
			target:      'chat_codexbot_ts_thread_scope_project'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/bind alpha ' + alpha_root, 'chat_codexbot_ts_thread_scope_project',
				'om_codexbot_ts_thread_scope_alpha_bind')
		}) or { panic(err) }
		assert alpha_bind.handled

		alpha_switch := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_scope_alpha_switch'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_scope_alpha_switch'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_scope_alpha_switch'
			target:      'chat_codexbot_ts_thread_scope_project'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/project alpha', 'chat_codexbot_ts_thread_scope_project',
				'om_codexbot_ts_thread_scope_alpha_switch')
		}) or { panic(err) }
		assert alpha_switch.handled

		alpha_task := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_scope_alpha_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_scope_alpha_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_scope_alpha_task'
			target:      'chat_codexbot_ts_thread_scope_project'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('alpha task body', 'chat_codexbot_ts_thread_scope_project',
				'om_codexbot_ts_thread_scope_alpha_task')
		}) or { panic(err) }
		alpha_stream_id := codexbot_ts_first_stream_id(alpha_task.commands)
		assert alpha_stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_scope_alpha_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   alpha_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_scope_shared"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_scope_alpha_done'
			provider:   'codex'
			instance:   'main'
			trace_id:   alpha_stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{}}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_scope_alpha_read'
			provider:   'codex'
			instance:   'main'
			trace_id:   alpha_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_scope_shared","turns":[{"id":"turn_thread_scope_shared","items":[{"type":"agentMessage","id":"item_thread_scope_shared","text":"alpha answer","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }

		beta_bind := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_scope_beta_bind'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_scope_beta_bind'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_scope_beta_bind'
			target:      'chat_codexbot_ts_thread_scope_project'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/bind beta ' + beta_root, 'chat_codexbot_ts_thread_scope_project',
				'om_codexbot_ts_thread_scope_beta_bind')
		}) or { panic(err) }
		assert beta_bind.handled

		projects_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_scope_projects'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_scope_projects'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_scope_projects'
			target:      'chat_codexbot_ts_thread_scope_project'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/projects', 'chat_codexbot_ts_thread_scope_project',
				'om_codexbot_ts_thread_scope_projects')
		}) or { panic(err) }
		assert projects_resp.handled

		use_beta := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_scope_use_beta'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_scope_use_beta'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_scope_use_beta'
			target:      'chat_codexbot_ts_thread_scope_project'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/use beta', 'chat_codexbot_ts_thread_scope_project',
				'om_codexbot_ts_thread_scope_use_beta')
		}) or { panic(err) }
		assert use_beta.handled
		assert use_beta.commands[0].text.contains('Project: `beta`')

		thread_after_switch := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_scope_after_switch'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_scope_after_switch'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_scope_after_switch'
			target:      'chat_codexbot_ts_thread_scope_project'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/thread', 'chat_codexbot_ts_thread_scope_project',
				'om_codexbot_ts_thread_scope_after_switch')
		}) or { panic(err) }
		assert thread_after_switch.handled
		assert thread_after_switch.commands[0].text.contains('No thread is currently bound.')
		assert !thread_after_switch.commands[0].text.contains(alpha_stream_id)
		assert !thread_after_switch.commands[0].text.contains('alpha task body')
		assert !thread_after_switch.commands[0].text.contains('thread_scope_shared')

		beta_task := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_scope_beta_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_scope_beta_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_scope_beta_task'
			target:      'chat_codexbot_ts_thread_scope_project'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('beta task body', 'chat_codexbot_ts_thread_scope_project',
				'om_codexbot_ts_thread_scope_beta_task')
		}) or { panic(err) }
		beta_stream_id := codexbot_ts_first_stream_id(beta_task.commands)
		assert beta_stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_scope_beta_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   beta_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_scope_shared"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_scope_beta_done'
			provider:   'codex'
			instance:   'main'
			trace_id:   beta_stream_id
			event_type: 'codex.notification'
			payload:    '{"method":"turn/completed","params":{}}'
		}) or { panic(err) }

		thread_selected := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_thread_scope_select_shared'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_scope_select_shared'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_scope_select_shared'
			target:      'chat_codexbot_ts_thread_scope_project'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('/thread thread_scope_shared', 'chat_codexbot_ts_thread_scope_project',
				'om_codexbot_ts_thread_scope_select_shared')
		}) or { panic(err) }
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
		first_stream_id := codexbot_ts_first_stream_id(first_task.commands)
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
		use_stream_id := codexbot_ts_first_stream_id(use_resp.commands)
		assert use_stream_id != ''

		read_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_use_latest_read_rpc'
			provider:   'codex'
			instance:   'main'
			trace_id:   use_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_use_latest_001","turns":[{"id":"turn_thread_use_latest_001","items":[{"type":"agentMessage","id":"item_thread_use_latest_001","text":"hello from latest thread","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
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
		assert second_task.commands.len == 1
		assert second_task.commands[0].type_ == 'provider.rpc.call'
		assert second_task.commands[0].method == 'turn/start'
		assert second_task.commands[0].params.contains('"threadId":"thread_use_latest_001"')

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
		first_stream_id := codexbot_ts_first_stream_id(first_task.commands)
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
			payload:     codexbot_ts_feishu_payload('/thread rename Stable Name', 'chat_codexbot_ts_thread_rename',
				'om_codexbot_thread_rename_cmd')
		}) or { panic(err) }
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
