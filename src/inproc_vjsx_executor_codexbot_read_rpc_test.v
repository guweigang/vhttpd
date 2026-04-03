module main

import os

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
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_read_content_projection_001","turns":[{"id":"turn_read_content_projection_001","items":[{"type":"agentMessage","id":"item_read_content_projection_001","text":"line one\\nline two","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 2
		assert read_resp.commands[0].type_ == 'provider.message.send'
		assert read_resp.commands[0].text.contains('line one')
		assert read_resp.commands[0].text.contains('line two')
		assert read_resp.commands[1].type_ == 'stream.finish'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_read_prefers_current_turn_over_previous_final_answer() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_read_current_turn.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_thread_read_current_turn_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_read_current_turn_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_read_current_turn_task'
			target:      'chat_codexbot_ts_thread_read_current_turn'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('show me the latest turn only', 'chat_codexbot_ts_thread_read_current_turn',
				'om_codexbot_ts_thread_read_current_turn_task')
		}) or { panic(err) }
		stream_id := task_resp.commands[0].stream_id
		assert stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_current_turn_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_read_current_turn_001"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_current_turn_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turnId":"turn_read_current_turn_001","status":"inProgress","items":[]},"has_error":false}'
		}) or { panic(err) }

		read_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_current_turn_response'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_read_current_turn_001","turns":[{"id":"turn_old_current_turn_001","items":[{"type":"agentMessage","id":"item_old_current_turn_001","text":"old final answer","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null},{"id":"turn_read_current_turn_001","items":[{"type":"agentMessage","id":"item_read_current_turn_001","text":"new answer from latest turn","phase":"commentary","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 2
		assert read_resp.commands[0].type_ == 'provider.message.send'
		assert read_resp.commands[0].text.contains('new answer from latest turn')
		assert !read_resp.commands[0].text.contains('old final answer')
		assert read_resp.commands[1].type_ == 'stream.finish'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_read_combines_multiple_assistant_items_from_same_turn() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_read_multi_item.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_thread_read_multi_item_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_read_multi_item_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_read_multi_item_task'
			target:      'chat_codexbot_ts_thread_read_multi_item'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('show the full multi-part answer', 'chat_codexbot_ts_thread_read_multi_item',
				'om_codexbot_ts_thread_read_multi_item_task')
		}) or { panic(err) }
		stream_id := codexbot_ts_first_stream_id(task_resp.commands)
		assert stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_multi_item_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_read_multi_item_001"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_multi_item_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turnId":"turn_read_multi_item_001","status":"inProgress","items":[]},"has_error":false}'
		}) or { panic(err) }

		read_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_multi_item_response'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_read_multi_item_001","turns":[{"id":"turn_read_multi_item_001","items":[{"type":"agentMessage","id":"item_read_multi_item_001","text":"第一段：进度总览。","phase":"commentary","memoryCitation":null},{"type":"agentMessage","id":"item_read_multi_item_002","text":"第二段：剩余风险和下一步。","phase":"commentary","memoryCitation":null}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 4
		assert read_resp.commands[0].type_ == 'provider.message.send'
		assert read_resp.commands[0].text == '第一段：进度总览。'
		assert read_resp.commands[1].type_ == 'stream.finish'
		assert read_resp.commands[2].type_ == 'provider.message.send'
		assert read_resp.commands[2].text == '第二段：剩余风险和下一步。'
		assert read_resp.commands[3].type_ == 'stream.finish'
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_read_does_not_surface_previous_turn_during_active_plain_ask() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_read_preferred_turn_fallback.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_thread_read_preferred_turn_fallback_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_read_preferred_turn_fallback_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_read_preferred_turn_fallback_task'
			target:      'chat_codexbot_ts_thread_read_preferred_turn_fallback'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('show the latest visible answer', 'chat_codexbot_ts_thread_read_preferred_turn_fallback',
				'om_codexbot_ts_thread_read_preferred_turn_fallback_task')
		}) or { panic(err) }
		stream_id := codexbot_ts_first_stream_id(task_resp.commands)
		assert stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_preferred_turn_fallback_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_read_preferred_turn_fallback_001"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_preferred_turn_fallback_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turnId":"turn_read_preferred_turn_fallback_002","status":"inProgress","items":[]},"has_error":false}'
		}) or { panic(err) }

		read_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_preferred_turn_fallback_response'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_read_preferred_turn_fallback_001","turns":[{"id":"turn_read_preferred_turn_fallback_001","items":[{"type":"agentMessage","id":"item_read_preferred_turn_fallback_001","text":"visible assistant answer from previous completed turn","phase":"final_answer","memoryCitation":null}],"status":"completed","error":null},{"id":"turn_read_preferred_turn_fallback_002","items":[{"type":"userMessage","id":"item_read_preferred_turn_fallback_002","content":[{"type":"text","text":"show the latest visible answer","text_elements":[]}]}],"status":"completed","error":null}]}},"has_error":false}'
		}) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 0
	})
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_thread_read_does_not_surface_partial_current_turn_during_active_plain_ask() {
	codexbot_ts_with_temp_db('codexbot_ts_thread_read_active_partial.sqlite', fn (_ string) {
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
			id:          'codexbot_ts_thread_read_active_partial_task'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_thread_read_active_partial_task'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_ts_thread_read_active_partial_task'
			target:      'chat_codexbot_ts_thread_read_active_partial'
			target_type: 'chat_id'
			payload:     codexbot_ts_feishu_payload('你帮我分析一下吧', 'chat_codexbot_ts_thread_read_active_partial',
				'om_codexbot_ts_thread_read_active_partial_task')
		}) or { panic(err) }
		stream_id := codexbot_ts_first_stream_id(task_resp.commands)
		assert stream_id != ''
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_active_partial_thread'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/start","result":{"threadId":"thread_read_active_partial_001"},"has_error":false}'
		}) or { panic(err) }
		_ = executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_active_partial_turn'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"turn/start","result":{"turnId":"turn_read_active_partial_001","status":"inProgress","items":[]},"has_error":false}'
		}) or { panic(err) }

		read_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'codexbot_ts_thread_read_active_partial_response'
			provider:   'codex'
			instance:   'main'
			trace_id:   stream_id
			event_type: 'codex.rpc.response'
			payload:    '{"method":"thread/read","result":{"thread":{"id":"thread_read_active_partial_001","status":{"type":"active","activeFlags":[]},"turns":[{"id":"turn_read_active_partial_001","items":[{"type":"agentMessage","id":"item_read_active_partial_001","text":"第一段：先给你一个初步判断。","phase":"commentary","memoryCitation":null}],"status":"inProgress","error":null}]}},"has_error":false}'
		}) or { panic(err) }
		assert read_resp.handled
		assert read_resp.commands.len == 0
	})
}
