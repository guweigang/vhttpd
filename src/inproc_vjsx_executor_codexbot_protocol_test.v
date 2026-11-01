module main

import upstream.transport

fn test_codexbot_application_resolves_raw_notification_without_native_stream_mapping() {
	codexbot_ts_with_harness('codexbot_raw_protocol.sqlite', false, fn (mut harness CodexbotTsTestHarness) {
		_, stream_id := harness.start_task('raw-task', 'raw-trace', 'raw-chat', 'raw-message', 'run raw protocol task') or { panic(err) }
		start := harness.dispatch_codex_event('raw-thread', stream_id, 'codex.rpc.response', '{"method":"thread/start","result":{"thread":{"id":"raw-thread-id"}},"has_error":false}') or { panic(err) }
		assert start.handled
		turn := harness.dispatch_codex_event('raw-turn', stream_id, 'codex.rpc.response', '{"method":"turn/start","result":{"turn":{"id":"raw-turn-id"}},"has_error":false}') or { panic(err) }
		assert turn.handled
		result := harness.dispatch_codex_event('raw-delta', '', 'codex.notification', '{"method":"item/agentMessage/delta","params":{"threadId":"raw-thread-id","turnId":"raw-turn-id","itemId":"raw-item","delta":"raw text"}}') or { panic(err) }
		assert result.handled
		assert result.commands.len > 0
		assert result.commands.any(it.stream_id == stream_id)
		unknown := harness.dispatch_codex_event('raw-unknown', '', 'codex.notification', '{"method":"future/new","params":{"threadId":"raw-thread-id"}}') or { panic(err) }
		assert !unknown.handled
	})
}

fn test_codexbot_application_handles_raw_feishu_event_without_native_chat_metadata() {
	codexbot_ts_with_harness('codexbot_raw_feishu.sqlite', false, fn (mut harness CodexbotTsTestHarness) {
		response := harness.executor.dispatch_websocket_upstream(mut harness.app, transport.WorkerWebSocketUpstreamDispatchRequest{
			mode: 'websocket_upstream'
			event: 'message'
			id: 'raw-feishu'
			provider: 'feishu'
			instance: 'main'
			event_type: 'feishu.event'
			payload: '{"schema":"2.0","header":{"event_type":"im.message.receive_v1","event_id":"raw-feishu-id"},"event":{"sender":{"sender_id":{"open_id":"synthetic-user"}},"message":{"message_id":"raw-feishu-message","chat_id":"raw-feishu-chat","message_type":"text","content":"{\\"text\\":\\"/help\\"}"}}}'
		}) or { panic(err) }
		assert response.handled
		assert response.commands.len > 0
		assert response.commands[0].target == 'raw-feishu-chat'
	})
}
