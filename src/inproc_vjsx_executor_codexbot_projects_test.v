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
		alpha_stream_id := codexbot_ts_first_stream_id(alpha_task.commands)
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
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_alpha_read'
			provider:   'codex'
			instance:   'main'
			trace_id:   alpha_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_project_alpha","turns":[{"id":"turn_thread_project_alpha","items":[{"type":"agentMessage","id":"item_thread_project_alpha","text":"alpha result","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
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
		beta_stream_id := codexbot_ts_first_stream_id(beta_task.commands)
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
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_beta_read'
			provider:   'codex'
			instance:   'main'
			trace_id:   beta_stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_project_beta","turns":[{"id":"turn_thread_project_beta","items":[{"type":"agentMessage","id":"item_thread_project_beta","text":"beta result","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
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
		stream_id := codexbot_ts_first_stream_id(task_resp.commands)
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
