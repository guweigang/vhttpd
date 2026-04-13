module main

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_handles_codex_approval_flow() {
	codexbot_ts_with_harness('codexbot_ts_approval_flow.sqlite', true, fn (mut harness CodexbotTsTestHarness) {
		_, stream_id := harness.start_task(
			'codexbot_ts_approval_task',
			'trace_codexbot_ts_approval_task',
			'chat_codexbot_ts_approval',
			'om_codexbot_ts_approval_task',
			'delete the temp file'
		) or { panic(err) }
		assert stream_id != ''

		thread_resp := harness.dispatch_codex_event(
			'codexbot_ts_approval_thread_start',
			stream_id,
			'codex.rpc.response',
			'{"method":"thread/start","result":{"threadId":"thread_approval_001"},"has_error":false}'
		) or { panic(err) }
		assert thread_resp.handled
		assert thread_resp.commands.len == 1
		assert thread_resp.commands[0].type_ == 'provider.rpc.call'
		assert thread_resp.commands[0].method == 'turn/start'

		turn_resp := harness.dispatch_codex_event(
			'codexbot_ts_approval_turn_start',
			stream_id,
			'codex.rpc.response',
			'{"method":"turn/start","result":{"turn":{"id":"turn_approval_001"}},"has_error":false}'
		) or { panic(err) }
		assert turn_resp.handled

		request_resp := harness.dispatch_codex_event(
			'codexbot_ts_approval_request',
			stream_id,
			'codex.server_request',
			'{"method":"item/commandExecution/requestApproval","id":0,"params":{"threadId":"thread_approval_001","turnId":"turn_approval_001","itemId":"item_approval_001","reason":"delete temp file","command":"rm -f tmp/demo.txt","cwd":"/Users/guweigang/Source/vhttpd","availableDecisions":["accept","acceptForSession","decline"]}}'
		) or { panic(err) }
		assert request_resp.handled
		assert request_resp.commands.len == 1
		assert request_resp.commands[0].type_ == 'provider.message.send'
		assert request_resp.commands[0].provider == 'feishu'
		assert request_resp.commands[0].stream_id != ''
		assert request_resp.commands[0].content.contains('"requestId":"thread_approval_001::turn_approval_001::item_approval_001::item/commandExecution/requestApproval::0"')
		assert request_resp.commands[0].content.contains('rm -f tmp/demo.txt')
		approval_stream_id := request_resp.commands[0].stream_id

		action_resp := harness.dispatch_feishu_action(
			'codexbot_ts_approval_action',
			'trace_codexbot_ts_approval_action',
			'om_codexbot_ts_approval_card',
			'thread_approval_001::turn_approval_001::item_approval_001::item/commandExecution/requestApproval::0',
			'accept',
			'evt_codexbot_ts_approval_action'
		) or { panic(err) }
		assert action_resp.handled
		assert action_resp.commands.len == 1
		assert action_resp.commands[0].type_ == 'provider.rpc.reply'
		assert action_resp.commands[0].provider == 'codex'
		assert action_resp.commands[0].metadata['id'] == '0'
		assert action_resp.commands[0].content.contains('"decision":"accept"')

		resolved_resp := harness.dispatch_codex_event(
			'codexbot_ts_approval_resolved',
			stream_id,
			'codex.notification',
			'{"method":"serverRequest/resolved","params":{"threadId":"thread_approval_001","requestId":0}}'
		) or { panic(err) }
		assert resolved_resp.handled
		assert resolved_resp.commands.len == 1
		assert resolved_resp.commands[0].type_ == 'provider.message.update'
		assert resolved_resp.commands[0].stream_id == approval_stream_id
		assert resolved_resp.commands[0].content.contains('Codex 已确认该审批请求已结束')
	})
}
