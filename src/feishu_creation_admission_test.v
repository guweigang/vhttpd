module main

import command
import config
import executor as execmod
import feishu
import json2 as json
import net.websocket
import upstream
import upstream.transport

fn creation_app_fixture() &App {
	return &App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				enabled:        true
				open_base_url:  'https://open.feishu.test/open-apis'
				apps:           {
					'main': config.FeishuAppConfig{ app_id: 'cli', app_secret: 'secret' }
				}
				http_test_stub: true
			}
		}
	}
}

fn creation_packet(kind string, lease feishu.CreationLease) transport.WorkerWebSocketUpstreamCommand {
	return transport.WorkerWebSocketUpstreamCommand{
		type_:       kind
		provider:    'feishu'
		instance:    'main'
		stream_id:   'stream'
		target:      if kind == 'provider.message.send' { 'chat' } else { 'message' }
		target_type: if kind == 'provider.message.send' { 'chat_id' } else { 'message_id' }
		text:        'hello'
		metadata:    if kind == 'session.bind' {
			{
				'creation_generation': lease.generation
				'creation_token':      lease.token
			}
		} else {
			{
				'stream_generation': lease.generation
				'creation_token':    lease.token
			}
		}
	}
}

fn creation_execute(mut app App, packet transport.WorkerWebSocketUpstreamCommand) execmod.WebSocketUpstreamCommandActivity {
	mut handler := FeishuCommandHandler.new(mut app)
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handled, _ := handler.execute(packet, command.NormalizedCommand.from_worker_command(packet), mut activity)
	assert handled
	return activity
}

fn creation_clear(mut app App, generation string) {
	packet := transport.WorkerWebSocketUpstreamCommand{
		type_:     'session.clear'
		provider:  'feishu'
		instance:  'main'
		stream_id: 'stream'
		metadata:  {
			'stream_generation': generation
		}
	}
	assert creation_execute(mut app, packet).status == 'cleared'
}

fn test_creation_unknown_bind_and_send_cannot_create_from_absence() {
	for kind in ['session.bind', 'provider.message.send'] {
		for generation in ['', 'producer-invented'] {
			mut app := creation_app_fixture()
			assert creation_execute(mut app, creation_packet(kind, feishu.CreationLease{ generation: generation })).status == 'error'
			assert app.providers.feishu.buffers.len == 0
			assert app.codex_find_stream_targets('stream').len == 0
			assert app.providers.feishu.http_test_calls == 0
		}
	}
}

fn test_creation_revocation_before_first_delivery_blocks_prebuilt_bind_send() {
	for kind in ['session.bind', 'provider.message.send'] {
		mut app := creation_app_fixture()
		generation := creation_issue_fixture(mut app, kind)
		packet := creation_packet(kind, generation)
		creation_clear(mut app, generation.generation)
		assert creation_execute(mut app, packet).status == 'error'
		assert app.providers.feishu.http_test_calls == 0
		assert app.providers.feishu.buffers.len == 0
		assert app.codex_find_stream_targets('stream').len == 0
	}
}

fn test_creation_consumed_bind_send_replay_cannot_rebuild_after_withdrawal() {
	for kind in ['session.bind', 'provider.message.send'] {
		mut app := creation_app_fixture()
		generation := creation_issue_fixture(mut app, kind)
		packet := creation_packet(kind, generation)
		first := creation_execute(mut app, packet)
		assert first.status == if kind == 'session.bind' { 'bound' } else { 'sent' }
		assert first.stream_generation != ''
		assert app.providers.feishu.buffers.len == 1
		assert app.codex_find_stream_targets('stream').len == 1
		creation_clear(mut app, first.stream_generation)
		calls := app.providers.feishu.http_test_calls
		assert creation_execute(mut app, packet).status == 'error'
		assert app.providers.feishu.http_test_calls == calls
		assert app.providers.feishu.buffers.len == 0
		assert app.codex_find_stream_targets('stream').len == 0
		fresh := creation_issue_fixture(mut app, kind)
		assert fresh.generation != generation.generation
		assert creation_execute(mut app, packet).status == 'error'
		assert creation_execute(mut app, creation_packet(kind, fresh)).status != 'error'
	}
}

fn test_creation_duplicate_concurrent_packets_spend_only_one_authority() {
	for kind in ['session.bind', 'provider.message.send'] {
		mut app := creation_app_fixture()
		generation := creation_issue_fixture(mut app, kind)
		packet := creation_packet(kind, generation)
		left := spawn creation_execute(mut app, packet)
		right := spawn creation_execute(mut app, packet)
		a := left.wait()
		b := right.wait()
		assert (a.status == 'error') != (b.status == 'error')
		assert app.providers.feishu.buffers.len == 1
		assert app.codex_find_stream_targets('stream').len == 1
		assert app.providers.feishu.http_test_calls == if kind == 'session.bind' { 0 } else { 2 }
	}
}

fn test_creation_bridge_send_independently_spends_and_rejects_replay() {
	mut app := creation_app_fixture()
	generation := app.providers.feishu.issue_wire_creation('stream', 'main') or { panic(err) }
	mut client := websocket.new_client('ws://localhost:12345') or { panic(err) }
	state := bridge_authority_test_server(mut app, client)
	packet := json.encode(feishu.BridgeProxyRequest{
		type_:      feishu.bridge_proxy_request_type
		request_id: 'send'
		action:     'send'
		request:    upstream.UpstreamSendRequest{
			provider:    'feishu'
			instance:    'main'
			target:      'chat'
			target_type: 'chat_id'
			text:        'hello'
			metadata:    {
				'stream_id':         'stream'
				'stream_generation': generation.generation
				'creation_token':    generation.token
			}
		}
	}).bytes()
	feishu_card_bridge_server_message_cb(mut client, &websocket.Message{ opcode: .text_frame, payload: packet }, state) or { panic(err) }
	assert app.providers.feishu.http_test_calls == 2
	app.providers.feishu.clear_stream_buffers('stream')
	feishu_card_bridge_server_message_cb(mut client, &websocket.Message{ opcode: .text_frame, payload: packet }, state) or { panic(err) }
	assert app.providers.feishu.http_test_calls == 2
	assert app.providers.feishu.buffers.len == 0
}

fn test_creation_bridge_revoked_or_unknown_grant_never_reaches_http() {
	for revoke in [false, true] {
		mut app := creation_app_fixture()
		generation := app.providers.feishu.issue_wire_creation('stream', 'main') or { panic(err) }
		if revoke { creation_clear(mut app, generation.generation) }
		mut client := websocket.new_client('ws://localhost:12345') or { panic(err) }
		state := bridge_authority_test_server(mut app, client)
		feishu_card_bridge_server_message_cb(mut client, &websocket.Message{
			opcode:  .text_frame
			payload: json.encode(feishu.BridgeProxyRequest{
				type_:      feishu.bridge_proxy_request_type
				request_id: 'late'
				action:     'send'
				request:    upstream.UpstreamSendRequest{
					provider:    'feishu'
					instance:    'main'
					target:      'chat'
					target_type: 'chat_id'
					metadata:    {
						'stream_id':         'stream'
						'creation_token':    generation.token
						'stream_generation': if revoke { generation.generation } else { 'forged' }
					}
				}
			}).bytes()
		}, state) or { panic(err) }
		assert app.providers.feishu.http_test_calls == 0
	}
}

fn creation_issue_fixture(mut app App, kind string) feishu.CreationLease {
	if kind == 'session.bind' {
		return app.providers.feishu.issue_wire_bind_creation('stream', 'main', 'message') or { panic(err) }
	}
	return app.providers.feishu.issue_wire_creation('stream', 'main') or { panic(err) }
}

fn test_creation_first_bind_physical_replacement_or_target_clear_fences_old_packet() {
	for rebind in [false, true] {
		mut app := creation_app_fixture()
		raw := app.issue_feishu_stream_creation('stream', 'main', 'message') or { panic(err) }
		lease := json.decode[feishu.CreationLease](raw) or { panic(err) }
		packet := creation_packet('session.bind', lease)
		if rebind {
			app.providers.feishu.register_stream_buffer('message', 'other-stream', 'main', '', '', '')
			app.providers.feishu.clear_buffer('message')
		} else {
			clear := transport.WorkerWebSocketUpstreamCommand{
				type_:       'session.clear'
				provider:    'feishu'
				instance:    'main'
				stream_id:   'stream'
				target_type: 'message_id'
				target:      'message'
				metadata:    {
					'stream_generation': lease.generation
				}
			}
			assert creation_execute(mut app, clear).status == 'cleared'
		}
		assert creation_execute(mut app, packet).status == 'error'
		assert app.providers.feishu.buffers.len == 0
		assert app.codex_find_stream_targets('stream').len == 0
		assert app.providers.feishu.http_test_calls == 0
	}
}
