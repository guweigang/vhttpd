module main

import codex
import command

fn test_codex_turn_can_bind_an_application_owned_reply_channel() {
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{
		connected: true
		initialized: true
		thread_id: 'thread'
	})
	prepared := app.codex_prepare_turn(command.NormalizedCommand{
		correlation: command.CommandCorrelation{stream_id: 'application-stream'}
		response_message_id: 'reply'
		metadata: {'reply_provider': 'application-channel'}
	})
	assert prepared.failure == ''
	targets := app.codex_stream_targets('main', 'application-stream')
	assert targets.len == 1
	assert targets[0].platform == 'application-channel'
	assert targets[0].message_id == 'reply'
}
