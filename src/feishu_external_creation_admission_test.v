module main

import command
import config
import executor as execmod
import feishu
import json2 as json
import net.http
import net.websocket
import upstream
import upstream.transport

fn external_creation_app_fixture() &App {
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

fn external_creation_packet(kind string, lease feishu.CreationLease) transport.WorkerWebSocketUpstreamCommand {
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

fn external_creation_execute(mut app App, packet transport.WorkerWebSocketUpstreamCommand) execmod.WebSocketUpstreamCommandActivity {
	mut handler := FeishuCommandHandler.new(mut app)
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handled, _ := handler.execute(packet, command.NormalizedCommand.from_worker_command(packet), mut activity)
	assert handled
	return activity
}

fn external_creation_clear(mut app App, generation string) {
	packet := transport.WorkerWebSocketUpstreamCommand{
		type_:     'session.clear'
		provider:  'feishu'
		instance:  'main'
		stream_id: 'stream'
		metadata:  {
			'stream_generation': generation
		}
	}
	assert external_creation_execute(mut app, packet).status == 'cleared'
}

// Existing admission fixtures exercise real command handlers and the HTTP stub.
fn test_external_issued_bind_send_replay_cannot_recreate_after_clear() {
	for kind in ['send', 'bind'] {
		mut app := external_creation_app_fixture()
		discovery := app.providers.feishu.external_creation_discovery() or { panic(err) }
		req := feishu.ExternalCreationRequest{
			epoch:      discovery.epoch
			issued_at:  discovery.issued_at
			request_id: 'a'.repeat(64)
			stream_id:  'stream'
			instance:   'main'
			kind:       kind
			message_id: if kind == 'bind' {
				'message'
			} else {
				''
			}
		}
		lease := app.issue_external_feishu_creation(req) or { panic(err) }
		packet := external_creation_packet(if kind == 'send' {
			'provider.message.send'
		} else {
			'session.bind'
		}, lease)
		activity := external_creation_execute(mut app, packet)
		assert activity.status == if kind == 'send' { 'sent' } else { 'bound' }
		external_creation_clear(mut app, activity.stream_generation)
		calls := app.providers.feishu.http_test_calls
		cached := app.issue_external_feishu_creation(req) or { panic(err) }
		assert cached == lease
		assert external_creation_execute(mut app, packet).status == 'error'
		assert app.providers.feishu.http_test_calls == calls
		assert app.providers.feishu.buffers.len == 0
		assert app.codex_find_stream_targets('stream').len == 0
	}
}

fn test_external_revoked_issuance_blocks_prebuilt_packets_and_reissuance() {
	for kind in ['send', 'bind'] {
		mut app := external_creation_app_fixture()
		discovery := app.providers.feishu.external_creation_discovery() or { panic(err) }
		req := feishu.ExternalCreationRequest{
			epoch:      discovery.epoch
			issued_at:  discovery.issued_at
			request_id: 'b'.repeat(64)
			stream_id:  'stream'
			instance:   'main'
			kind:       kind
			message_id: if kind == 'bind' {
				'message'
			} else {
				''
			}
		}
		lease := app.issue_external_feishu_creation(req) or { panic(err) }
		_ := app.providers.feishu.revoke_external_creation(req) or { panic(err) }
		if _ := app.issue_external_feishu_creation(req) {
			assert false
		}
		assert external_creation_execute(mut app, external_creation_packet(if kind == 'send' {
			'provider.message.send'
		} else {
			'session.bind'
		}, lease)).status == 'error'
		assert app.providers.feishu.http_test_calls == 0
		assert app.providers.feishu.buffers.len == 0
	}
}

fn test_bridge_revoke_creation_action_blocks_send_and_preserves_peer() {
	mut app := external_creation_app_fixture()
	lease := app.providers.feishu.issue_wire_creation('stream', 'main') or { panic(err) }
	peer := app.providers.feishu.issue_wire_creation('stream', 'main') or { panic(err) }
	mut client := websocket.Client{}
	state := bridge_authority_test_server(mut app, &client)
	raw := json.encode(feishu.BridgeProxyRequest{
		type_:      feishu.bridge_proxy_request_type
		request_id: 'revoke'
		action:     'revoke_creation'
		request:    upstream.UpstreamSendRequest{
			provider: 'feishu'
			instance: 'main'
			metadata: {
				'stream_id':         'stream'
				'stream_generation': lease.generation
				'creation_token':    lease.token
			}
		}
	})
	feishu_card_bridge_server_message_cb(mut client, &websocket.Message{ opcode: .text_frame, payload: raw.bytes() }, state) or { panic(err) }
	assert app.providers.feishu.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) == none
	claim := app.providers.feishu.admit_wire_initial_creation('stream', 'main', peer.generation, peer.token) or { panic('peer revoked') }
	app.providers.feishu.finish_initial_send(claim)
	assert app.providers.feishu.http_test_calls == 0
}

fn test_external_creation_request_projection_drops_query_credentials() {
	req := feishu_creation_request(Context{ req: http.Request{ url: '/admin/runtime/feishu/creation?token=secret' } }, '/admin/runtime/feishu/creation')
	assert req.path == '/admin/runtime/feishu/creation'
	assert !req.req_id.contains('secret')
	assert !req.trace_id.contains('secret')
}
