module main

import upstream.transport

fn test_ts_one_shot_reply_preserves_inbound_instance_through_real_host_issuance() {
	codexbot_ts_with_harness('codexbot_ts_one_shot_instance.sqlite', false, fn (mut harness CodexbotTsTestHarness) {
		response := harness.executor.dispatch_websocket_upstream(mut harness.app, transport.WorkerWebSocketUpstreamDispatchRequest{
			mode:       'websocket_upstream'
			event:      'message'
			id:         'instance-reply'
			provider:   'feishu'
			instance:   'secondary'
			event_type: 'im.message.receive_v1'
			target:     'chat'
			payload:    codexbot_ts_feishu_payload('/help', 'chat', 'instance-message')
		}) or { panic(err) }
		codexbot_ts_assert_one_shot_reply(response.commands)
		send := response.commands[0]
		assert send.instance == 'secondary'
		assert response.commands[1].instance == 'secondary'
		generation := send.metadata['stream_generation'] or { '' }
		token := send.metadata['creation_token'] or { '' }
		assert harness.app.creation_state.admit_wire_initial_creation(send.stream_id, 'main', generation, token) == none
		claim := harness.app.creation_state.admit_wire_initial_creation(send.stream_id, 'secondary', generation, token) or { panic('instance lost between issuance and command') }
		harness.app.creation_state.finish_initial_send(claim)
	})
}
