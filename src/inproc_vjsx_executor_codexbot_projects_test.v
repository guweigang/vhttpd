module main

import net.http
import os
import time

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_projects_and_models_commands_use_selection_scope() {
	codexbot_ts_with_temp_db('codexbot_ts_projects_models.sqlite', fn (_ string) {
		suffix := '${time.now().unix_milli()}'
		project_root := os.join_path(os.temp_dir(), 'codexbot_ts_projects_models_root_' + suffix)
		os.mkdir_all(project_root) or { panic(err) }
		os.mkdir_all(os.join_path(project_root, 'beta')) or { panic(err) }
		defer {
			os.rmdir_all(project_root) or {}
		}

		mut executor := codexbot_ts_new_executor(true)
		defer {
			executor.close()
		}
		mut app := App{}

		setting_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_projects_models_setting',
			'trace_codexbot_ts_projects_models_setting',
			'chat_codexbot_ts_projects_models',
			'om_codexbot_ts_projects_models_setting',
			'/setting project_root_dir ' + project_root
		) or { panic(err) }
		assert setting_resp.handled
		assert setting_resp.commands.len == 1
		assert setting_resp.commands[0].text.contains('**Setting Updated**')

		create_alpha := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_projects_models_create_alpha',
			'trace_codexbot_ts_projects_models_create_alpha',
			'chat_codexbot_ts_projects_models',
			'om_codexbot_ts_projects_models_create_alpha',
			'/create alpha'
		) or { panic(err) }
		assert create_alpha.handled
		assert create_alpha.commands.len == 1
		assert create_alpha.commands[0].text.contains('**Project Created**')
		assert create_alpha.commands[0].text.contains('Project: `alpha`')

		bind_beta := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_projects_models_bind_beta',
			'trace_codexbot_ts_projects_models_bind_beta',
			'chat_codexbot_ts_projects_models',
			'om_codexbot_ts_projects_models_bind_beta',
			'/bind beta'
		) or { panic(err) }
		assert bind_beta.handled
		assert bind_beta.commands.len == 1
		assert bind_beta.commands[0].text.contains('Project: `beta`')

		alpha_task, alpha_stream_id := codexbot_ts_start_task(
			mut executor,
			mut app,
			'codexbot_ts_alpha_task',
			'trace_codexbot_ts_alpha_task',
			'chat_codexbot_ts_projects_models',
			'om_codexbot_ts_alpha_task',
			'alpha task'
		) or { panic(err) }
		assert alpha_task.handled
		assert alpha_stream_id != ''
		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_alpha_rpc',
			alpha_stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_project_alpha"},"has_error":false}'
		) or { panic(err) }
		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_alpha_done',
			alpha_stream_id,
			'codex.notification',
			'{"method":"turn/completed","params":{}}'
		) or { panic(err) }
		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_alpha_read',
			alpha_stream_id,
			'codex.rpc.response',
			'{"method":"thread/read","result":{"thread":{"id":"thread_project_alpha","turns":[{"id":"turn_thread_project_alpha","items":[{"type":"agentMessage","id":"item_thread_project_alpha","text":"alpha result","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		) or { panic(err) }

		switch_beta := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_switch_beta',
			'trace_codexbot_ts_switch_beta',
			'chat_codexbot_ts_projects_models',
			'om_codexbot_ts_switch_beta',
			'/project beta'
		) or { panic(err) }
		assert switch_beta.commands[0].text.contains('Project: `beta`')

		beta_task, beta_stream_id := codexbot_ts_start_task(
			mut executor,
			mut app,
			'codexbot_ts_beta_task',
			'trace_codexbot_ts_beta_task',
			'chat_codexbot_ts_projects_models',
			'om_codexbot_ts_beta_task',
			'beta task'
		) or { panic(err) }
		assert beta_task.handled
		assert beta_stream_id != ''
		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_beta_rpc',
			beta_stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_project_beta"},"has_error":false}'
		) or { panic(err) }
		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_beta_done',
			beta_stream_id,
			'codex.notification',
			'{"method":"turn/completed","params":{}}'
		) or { panic(err) }
		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_beta_read',
			beta_stream_id,
			'codex.rpc.response',
			'{"method":"thread/read","result":{"thread":{"id":"thread_project_beta","turns":[{"id":"turn_thread_project_beta","items":[{"type":"agentMessage","id":"item_thread_project_beta","text":"beta result","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		) or { panic(err) }

		projects_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_projects_list',
			'trace_codexbot_ts_projects_list',
			'chat_codexbot_ts_projects_models',
			'om_codexbot_ts_projects_list',
			'/projects'
		) or { panic(err) }
		assert projects_resp.handled
		assert projects_resp.commands.len == 1
		assert projects_resp.commands[0].text.contains('**Projects**')
		assert projects_resp.commands[0].text.contains('Chat: `chat_codexbot_ts_projects_models`')
		assert projects_resp.commands[0].text.contains('alpha')
		assert projects_resp.commands[0].text.contains('`beta` current')

		use_project_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_projects_use_alpha',
			'trace_codexbot_ts_projects_use_alpha',
			'chat_codexbot_ts_projects_models',
			'om_codexbot_ts_projects_use_alpha',
			'/use alpha'
		) or { panic(err) }
		assert use_project_resp.handled
		assert use_project_resp.commands.len == 1
		assert use_project_resp.commands[0].text.contains('Project: `alpha`')

		use_project_resp_2 := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_projects_use_beta_again',
			'trace_codexbot_ts_projects_use_beta_again',
			'chat_codexbot_ts_projects_models',
			'om_codexbot_ts_projects_use_beta_again',
			'/use beta'
		) or { panic(err) }
		assert use_project_resp_2.handled
		assert use_project_resp_2.commands.len == 1
		assert use_project_resp_2.commands[0].text.contains('Project: `beta`')

		models_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_models_list',
			'trace_codexbot_ts_models_list',
			'chat_codexbot_ts_projects_models',
			'om_codexbot_ts_models_list',
			'/models'
		) or { panic(err) }
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
		use_after_scope_cleared_stream_id := codexbot_ts_first_stream_id(use_after_scope_cleared.commands)
		assert use_after_scope_cleared_stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_projects_use_after_scope_cleared_read'
			provider:   'codex'
			instance:   'main'
			trace_id:   use_after_scope_cleared_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"alpha","turns":[{"id":"turn_alpha_thread_restored","items":[{"type":"agentMessage","id":"item_alpha_thread_restored","text":"alpha thread restored","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }

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
		assert next_task.commands.len == 1
		assert next_task.commands[0].method == 'turn/start'
		assert next_task.commands[0].params.contains('"model":"gpt-5.4"')
		assert next_task.commands[0].params.contains('"threadId":"alpha"')
		assert next_task.commands[0].params.contains('/beta')
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_new_command_can_switch_model_and_clear_thread() {
	codexbot_ts_with_temp_db('codexbot_ts_new_model.sqlite', fn (_ string) {
		mut executor := codexbot_ts_new_executor(true)
		defer {
			executor.close()
		}
		mut app := App{}

		task_resp, stream_id := codexbot_ts_start_task(
			mut executor,
			mut app,
			'codexbot_ts_new_model_task',
			'trace_codexbot_ts_new_model_task',
			'chat_codexbot_ts_new_model',
			'om_codexbot_ts_new_model_task',
			'seed thread'
		) or { panic(err) }
		assert task_resp.handled
		assert stream_id != ''

		_ = codexbot_ts_dispatch_codex_event(
			mut executor,
			mut app,
			'codexbot_ts_new_model_rpc',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_new_model_001"},"has_error":false}'
		) or { panic(err) }

		reset_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_new_model_reset',
			'trace_codexbot_ts_new_model_reset',
			'chat_codexbot_ts_new_model',
			'om_codexbot_ts_new_model_reset',
			'/new gpt-5.3-codex'
		) or { panic(err) }
		assert reset_resp.handled
		assert reset_resp.commands.len == 1
		assert reset_resp.commands[0].text.contains('**New Conversation**')
		assert reset_resp.commands[0].text.contains('Previous Thread: `thread_new_model_001`')
		assert reset_resp.commands[0].text.contains('Model switched: `gpt-5.4` -> `gpt-5.3-codex`')

		thread_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_new_model_thread',
			'trace_codexbot_ts_new_model_thread',
			'chat_codexbot_ts_new_model',
			'om_codexbot_ts_new_model_thread',
			'/thread'
		) or { panic(err) }
		assert thread_resp.handled
		assert thread_resp.commands.len == 1
		assert thread_resp.commands[0].text.contains('No thread is currently bound.')

		model_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_new_model_model',
			'trace_codexbot_ts_new_model_model',
			'chat_codexbot_ts_new_model',
			'om_codexbot_ts_new_model_model',
			'/model'
		) or { panic(err) }
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

		mut executor := codexbot_ts_new_executor(true)
		defer {
			executor.close()
		}
		mut app := App{}

		setting_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_setting_project_root',
			'trace_codexbot_ts_setting_project_root',
			'chat_codexbot_ts_project_registry',
			'om_codexbot_ts_setting_project_root',
			'/setting project_root_dir ' + project_root
		) or { panic(err) }
		assert setting_resp.handled
		assert setting_resp.commands.len == 1
		assert setting_resp.commands[0].text.contains('**Setting Updated**')
		assert setting_resp.commands[0].text.contains('`project_root_dir` = `' + project_root + '`')

		create_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_create_project',
			'trace_codexbot_ts_create_project',
			'chat_codexbot_ts_project_registry',
			'om_codexbot_ts_create_project',
			'/create alpha'
		) or { panic(err) }
		assert create_resp.handled
		assert create_resp.commands.len == 1
		assert create_resp.commands[0].text.contains('**Project Created**')
		assert create_resp.commands[0].text.contains('Project: `alpha`')
		assert create_resp.commands[0].text.contains(os.join_path(project_root, 'alpha'))
		assert os.is_dir(os.join_path(project_root, 'alpha'))

		import_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_import_project',
			'trace_codexbot_ts_import_project',
			'chat_codexbot_ts_project_registry',
			'om_codexbot_ts_import_project',
			'/import beta ' + import_root
		) or { panic(err) }
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

		mut executor := codexbot_ts_new_executor(true)
		defer {
			executor.close()
		}
		mut app := App{}

		_ = codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_unbind_setting_project_root',
			'trace_codexbot_ts_unbind_setting_project_root',
			'chat_codexbot_ts_unbind',
			'om_codexbot_ts_unbind_setting_project_root',
			'/setting project_root_dir ' + project_root
		) or { panic(err) }

		create_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_unbind_create_alpha',
			'trace_codexbot_ts_unbind_create_alpha',
			'chat_codexbot_ts_unbind',
			'om_codexbot_ts_unbind_create_alpha',
			'/create alpha'
		) or { panic(err) }
		assert create_resp.handled
		assert create_resp.commands[0].text.contains('Project: `alpha`')

		bind_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_unbind_bind_beta',
			'trace_codexbot_ts_unbind_bind_beta',
			'chat_codexbot_ts_unbind',
			'om_codexbot_ts_unbind_bind_beta',
			'/bind beta'
		) or { panic(err) }
		assert bind_resp.handled
		assert bind_resp.commands[0].text.contains('Project: `beta`')

		blocked_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_unbind_alpha_blocked',
			'trace_codexbot_ts_unbind_alpha_blocked',
			'chat_codexbot_ts_unbind',
			'om_codexbot_ts_unbind_alpha_blocked',
			'/unbind alpha'
		) or { panic(err) }
		assert blocked_resp.handled
		assert blocked_resp.commands.len == 1
		assert blocked_resp.commands[0].text.contains('**Cannot Unbind Current Project**')
		assert blocked_resp.commands[0].text.contains('Project: `alpha`')

		unbind_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_unbind_beta',
			'trace_codexbot_ts_unbind_beta',
			'chat_codexbot_ts_unbind',
			'om_codexbot_ts_unbind_beta',
			'/unbind beta'
		) or { panic(err) }
		assert unbind_resp.handled
		assert unbind_resp.commands.len == 1
		assert unbind_resp.commands[0].text.contains('**Project Unbound**')
		assert unbind_resp.commands[0].text.contains('Project: `beta`')

		projects_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_unbind_projects',
			'trace_codexbot_ts_unbind_projects',
			'chat_codexbot_ts_unbind',
			'om_codexbot_ts_unbind_projects',
			'/projects'
		) or { panic(err) }
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

		mut executor := codexbot_ts_new_executor(true)
		defer {
			executor.close()
		}
		mut app := App{}

		_ = codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_create_bind_failures_setting',
			'trace_codexbot_ts_create_bind_failures_setting',
			'chat_codexbot_ts_create_bind_failures',
			'om_codexbot_ts_create_bind_failures_setting',
			'/setting project_root_dir ' + project_root
		) or { panic(err) }

		create_alpha := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_create_bind_failures_create_alpha',
			'trace_codexbot_ts_create_bind_failures_create_alpha',
			'chat_codexbot_ts_create_bind_failures',
			'om_codexbot_ts_create_bind_failures_create_alpha',
			'/create alpha'
		) or { panic(err) }
		assert create_alpha.handled
		assert create_alpha.commands[0].text.contains('**Project Created**')

		create_alpha_again := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_create_bind_failures_create_alpha_again',
			'trace_codexbot_ts_create_bind_failures_create_alpha_again',
			'chat_codexbot_ts_create_bind_failures',
			'om_codexbot_ts_create_bind_failures_create_alpha_again',
			'/create alpha'
		) or { panic(err) }
		assert create_alpha_again.handled
		assert create_alpha_again.commands.len == 1
		assert create_alpha_again.commands[0].text.contains('**Project Exists**')
		assert create_alpha_again.commands[0].text.contains('Project: `alpha`')
		assert create_alpha_again.commands[0].text.contains(os.join_path(project_root,
			'alpha'))

		create_gamma := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_create_bind_failures_create_gamma',
			'trace_codexbot_ts_create_bind_failures_create_gamma',
			'chat_codexbot_ts_create_bind_failures',
			'om_codexbot_ts_create_bind_failures_create_gamma',
			'/create gamma'
		) or { panic(err) }
		assert create_gamma.handled
		assert create_gamma.commands.len == 1
		assert create_gamma.commands[0].text.contains('**Project Directory Exists**')
		assert create_gamma.commands[0].text.contains('Project: `gamma`')
		assert create_gamma.commands[0].text.contains(os.join_path(project_root, 'gamma'))

		bind_beta := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_create_bind_failures_bind_beta',
			'trace_codexbot_ts_create_bind_failures_bind_beta',
			'chat_codexbot_ts_create_bind_failures',
			'om_codexbot_ts_create_bind_failures_bind_beta',
			'/bind beta ' + explicit_bind_root
		) or { panic(err) }
		assert bind_beta.handled
		assert bind_beta.commands.len == 1
		assert bind_beta.commands[0].text.contains('Project: `beta`')
		assert bind_beta.commands[0].text.contains(explicit_bind_root)

		bind_beta_again := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_create_bind_failures_bind_beta_again',
			'trace_codexbot_ts_create_bind_failures_bind_beta_again',
			'chat_codexbot_ts_create_bind_failures',
			'om_codexbot_ts_create_bind_failures_bind_beta_again',
			'/bind beta ' + explicit_bind_root
		) or { panic(err) }
		assert bind_beta_again.handled
		assert bind_beta_again.commands.len == 1
		assert bind_beta_again.commands[0].text.contains('**Project Path Already Bound**')
		assert bind_beta_again.commands[0].text.contains('Project: `beta`')
		assert bind_beta_again.commands[0].text.contains(explicit_bind_root)

		bind_missing := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_create_bind_failures_bind_missing',
			'trace_codexbot_ts_create_bind_failures_bind_missing',
			'chat_codexbot_ts_create_bind_failures',
			'om_codexbot_ts_create_bind_failures_bind_missing',
			'/bind delta ' + missing_bind_root
		) or { panic(err) }
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

		mut executor := codexbot_ts_new_executor(true)
		defer {
			executor.close()
		}
		mut app := App{}

		empty_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_settings_empty',
			'trace_codexbot_ts_settings_empty',
			'chat_codexbot_ts_settings',
			'om_codexbot_ts_settings_empty',
			'/settings'
		) or { panic(err) }
		assert empty_resp.handled
		assert empty_resp.commands.len == 1
		assert empty_resp.commands[0].text.contains('**Settings**')
		assert empty_resp.commands[0].text.contains('No settings configured yet.')

		create_without_setting := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_settings_create_fail',
			'trace_codexbot_ts_settings_create_fail',
			'chat_codexbot_ts_settings',
			'om_codexbot_ts_settings_create_fail',
			'/create gamma'
		) or { panic(err) }
		assert create_without_setting.handled
		assert create_without_setting.commands.len == 1
		assert create_without_setting.commands[0].text.contains('**Project Root Missing**')

		setting_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_settings_update',
			'trace_codexbot_ts_settings_update',
			'chat_codexbot_ts_settings',
			'om_codexbot_ts_settings_update',
			'/setting project_root_dir ' + project_root
		) or { panic(err) }
		assert setting_resp.handled
		assert setting_resp.commands.len == 1
		assert setting_resp.commands[0].text.contains('`project_root_dir` = `' + project_root + '`')

		list_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_settings_list',
			'trace_codexbot_ts_settings_list',
			'chat_codexbot_ts_settings',
			'om_codexbot_ts_settings_list',
			'/settings'
		) or { panic(err) }
		assert list_resp.handled
		assert list_resp.commands.len == 1
		assert list_resp.commands[0].text.contains('**Current Settings**')
		assert list_resp.commands[0].text.contains('`project_root_dir` = `' + project_root + '`')

		create_resp := codexbot_ts_dispatch_feishu_message(
			mut executor,
			mut app,
			'codexbot_ts_settings_create_ok',
			'trace_codexbot_ts_settings_create_ok',
			'chat_codexbot_ts_settings',
			'om_codexbot_ts_settings_create_ok',
			'/create gamma'
		) or { panic(err) }
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
		mutator_dir := os.join_path(os.temp_dir(), 'codexbot_ts_instances_legacy_alias_mutator_' +
			suffix)
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
			method:      'GET'
			path:        '/seed'
			req:         http.Request{
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
