module main

import command
import config
import executor as execmod
import feishu
import json2 as json
import net.websocket
import upstream
import upstream.transport

fn reply_failure_app() &App {
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

fn reply_failure_packet(kind string, lease feishu.CreationLease) transport.WorkerWebSocketUpstreamCommand {
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

fn reply_failure_execute(mut app App, packet transport.WorkerWebSocketUpstreamCommand) execmod.WebSocketUpstreamCommandActivity {
	mut handler := FeishuCommandHandler.new(mut app)
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handled, _ := handler.execute(packet, command.NormalizedCommand.from_worker_command(packet), mut activity)
	assert handled
	return activity
}

fn test_one_shot_native_send_completes_without_clear_or_runtime_publication() {
	mut app := reply_failure_app()
	scope := 'feishu:reply:interrupted'
	lease := app.providers.feishu.issue_wire_creation(scope, 'main') or { panic(err) }
	base := reply_failure_packet('provider.message.send', lease)
	packet := transport.WorkerWebSocketUpstreamCommand{ ...base, stream_id: scope }
	first := reply_failure_execute(mut app, packet)
	assert first.status == 'sent'
	assert first.stream_generation == lease.generation
	assert app.providers.feishu.buffers.len == 0
	assert app.codex_find_stream_targets(scope).len == 0
	calls := app.providers.feishu.http_test_calls
	assert reply_failure_execute(mut app, packet).status == 'error'
	assert app.providers.feishu.http_test_calls == calls
	for _ in 0 .. 2 {
		clear := transport.WorkerWebSocketUpstreamCommand{
			type_:     'session.clear'
			provider:  'feishu'
			instance:  'main'
			stream_id: scope
			metadata:  {
				'stream_generation': lease.generation
			}
		}
		assert reply_failure_execute(mut app, clear).status == 'cleared'
	}
	assert app.providers.feishu.buffers.len == 0
}

fn test_one_shot_bridge_send_completes_without_waiting_for_cleanup_or_reply_delivery() {
	mut app := reply_failure_app()
	scope := 'feishu:reply:bridge-interrupted'
	lease := app.providers.feishu.issue_wire_creation(scope, 'main') or { panic(err) }
	mut client := websocket.new_client('ws://localhost:12345') or { panic(err) }
	state := bridge_authority_test_server(mut app, client)
	packet := json.encode(feishu.BridgeProxyRequest{
		type_:      feishu.bridge_proxy_request_type
		request_id: 'reply'
		action:     'send'
		request:    upstream.UpstreamSendRequest{
			provider:    'feishu'
			instance:    'main'
			target:      'chat'
			target_type: 'chat_id'
			text:        'hello'
			metadata:    {
				'stream_id':         scope
				'stream_generation': lease.generation
				'creation_token':    lease.token
			}
		}
	}).bytes()
	// The synthetic connection cannot receive a result: publication must already
	// be terminal when the callback tries and fails to deliver that result.
	feishu_card_bridge_server_message_cb(mut client, &websocket.Message{ opcode: .text_frame, payload: packet }, state) or { panic(err) }
	calls := app.providers.feishu.http_test_calls
	assert calls == 2
	assert app.providers.feishu.buffers.len == 0
	assert app.codex_find_stream_targets(scope).len == 0
	feishu_card_bridge_server_message_cb(mut client, &websocket.Message{ opcode: .text_frame, payload: packet }, state) or { panic(err) }
	assert app.providers.feishu.http_test_calls == calls
}
