module main

fn test_ts_one_shot_help_uses_host_credentials_and_replay_cannot_refresh_revoked_scope() {
	codexbot_ts_with_harness('codexbot_ts_one_shot.sqlite', false, fn (mut harness CodexbotTsTestHarness) {
		old := harness.dispatch_feishu_message('reply-old', 'trace-old', 'chat', 'message-old', '/help') or { panic(err) }
		codexbot_ts_assert_one_shot_reply(old.commands)
		send := old.commands[0]
		scope := send.stream_id
		generation := send.metadata['stream_generation'] or { '' }
		token := send.metadata['creation_token'] or { '' }
		harness.app.creation_state.clear_stream_buffers(scope)
		fresh := harness.dispatch_feishu_message('reply-fresh', 'trace-fresh', 'chat', 'message-fresh', '/help') or { panic(err) }
		codexbot_ts_assert_one_shot_reply(fresh.commands)
		assert fresh.commands[0].stream_id != scope
		assert old.commands[0].metadata['stream_generation'] == generation
		assert harness.app.creation_state.admit_wire_initial_creation(scope, 'main', generation, token) == none
		assert harness.app.creation_state.admit_wire_initial_creation('', 'main', generation, token) == none
		current := fresh.commands[0]
		claim := harness.app.creation_state.admit_wire_initial_creation(current.stream_id, 'main', current.metadata['stream_generation'] or { '' }, current.metadata['creation_token'] or { '' }) or { panic('new reply permission lost') }
		harness.app.creation_state.finish_initial_send(claim)
		assert harness.app.creation_state.admit_wire_initial_creation(current.stream_id, 'main', current.metadata['stream_generation'] or { '' }, current.metadata['creation_token'] or { '' }) == none
	})
}
