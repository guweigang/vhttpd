module main

import codex
import command
import config
import executor as execmod
import feishu
import json2 as json
import net.http
import net.websocket
import upstream
import upstream.transport

fn cross_external_creation_app_fixture() &App {
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

fn cross_external_creation_packet(kind string, lease feishu.CreationLease) transport.WorkerWebSocketUpstreamCommand {
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

fn cross_external_creation_execute(mut app App, packet transport.WorkerWebSocketUpstreamCommand) execmod.WebSocketUpstreamCommandActivity {
	mut handler := FeishuCommandHandler.new(mut app)
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handled, _ := handler.execute(packet, command.NormalizedCommand.from_worker_command(packet), mut activity)
	assert handled
	return activity
}

fn cross_external_creation_clear(mut app App, generation string) {
	packet := transport.WorkerWebSocketUpstreamCommand{
		type_:     'session.clear'
		provider:  'feishu'
		instance:  'main'
		stream_id: 'stream'
		metadata:  {
			'stream_generation': generation
		}
	}
	assert cross_external_creation_execute(mut app, packet).status == 'cleared'
}

fn cross_host_mirror(mut app App, owner &feishu.BridgeAuthority, stream string, message string) feishu.CreationLease {
	issue := app.providers.feishu.begin_creation_issue(stream, 'main') or { panic(err) }
	mut remote := feishu.FeishuState{}
	lease := remote.issue_wire_creation(stream, 'main') or { panic(err) }
	app.providers.feishu.complete_bridge_creation_issue(issue, lease, owner) or { panic(err) }
	claim := app.providers.feishu.admit_wire_initial_creation(stream, 'main', lease.generation, lease.token) or { panic('mirror') }
	app.providers.feishu.mu.@lock()
	assert app.providers.feishu.commit_initial_send_generation_unlocked(claim, message, 'main', '', '', 'owned', lease.generation)
	app.providers.feishu.mu.unlock()
	app.providers.feishu.finish_initial_send(claim)
	app.codex_add_stream_target('main', stream, codex.CodexTarget{ platform: 'feishu', message_id: message, stream_generation: lease.generation })
	return lease
}

fn test_cross_host_disconnect_retires_local_mirror_and_paired_registry() {
	mut app := cross_external_creation_app_fixture()
	mut bridge := app.bridge_context()
	client := &websocket.Client{}
	bridge.set_client_conn(client)
	owner := app.providers.feishu.card_bridge_client_authority or { panic('owner') }
	lease := cross_host_mirror(mut app, owner, 'stream', 'message')
	bridge.clear_client_conn(client)
	assert app.providers.feishu.buffers.len == 0
	assert app.codex_find_stream_targets('stream').len == 0
	assert app.providers.feishu.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) == none
}

fn test_cross_host_delivered_result_cannot_publish_after_disconnect() {
	mut app := cross_external_creation_app_fixture()
	mut bridge := app.bridge_context()
	client := &websocket.Client{}
	bridge.set_client_conn(client)
	ch := chan feishu.BridgeProxyResult{cap: 1}
	id := bridge.register_proxy_pending(ch) or { panic(err) }
	owner, _ := bridge.proxy_request_owner(id) or { panic(err) }
	issue := app.providers.feishu.begin_creation_issue('stream', 'main') or { panic(err) }
	delivered := bridge.take_proxy_pending_from(id, client) or { panic('waiter') }
	delivered <- feishu.BridgeProxyResult{ ok: true, stream_generation: 'old', creation_token: 'a'.repeat(64) }
	bridge.clear_client_conn(client)
	result := <-ch
	if _ := app.providers.feishu.complete_bridge_creation_issue(issue, feishu.CreationLease{ generation: result.stream_generation, token: result.creation_token }, owner) {
		assert false
	}
	app.providers.feishu.finish_creation_issue(issue)
	assert app.providers.feishu.admit_wire_initial_creation('stream', 'main', result.stream_generation, result.creation_token) == none
}

fn test_cross_host_failed_clear_closes_exact_connection_and_retires_peers() {
	mut app := cross_external_creation_app_fixture()
	app.providers.feishu.card_bridge_enabled_flag = true
	app.providers.feishu.card_bridge_ws_url = 'ws://fixture.invalid'
	mut bridge := app.bridge_context()
	client := &websocket.Client{}
	bridge.set_client_conn(client)
	owner := app.providers.feishu.card_bridge_client_authority or { panic('owner') }
	lease := cross_host_mirror(mut app, owner, 'stream', 'message')
	_ := cross_host_mirror(mut app, owner, 'peer', 'peer-message')
	activity := cross_external_creation_execute(mut app, transport.WorkerWebSocketUpstreamCommand{
		type_:     'session.clear'
		provider:  'feishu'
		instance:  'main'
		stream_id: 'stream'
		metadata:  {
			'stream_generation': lease.generation
		}
	})
	assert activity.status == 'error'
	assert app.providers.feishu.card_bridge_client_conn == none
	assert app.providers.feishu.buffers.len == 0
	assert app.codex_find_stream_targets('peer').len == 0
	next := &websocket.Client{}
	bridge.set_client_conn(next)
	current := app.providers.feishu.card_bridge_client_authority or { panic('new owner') }
	_ := cross_host_mirror(mut app, current, 'stream', 'message')
	bridge.break_client_conn(client)
	active := bridge.client_conn() or { panic('connection disappeared') }
	assert active == next
	assert app.providers.feishu.buffers['message'].content == 'owned'
	assert app.codex_find_stream_targets('stream').len == 1
}

fn test_cross_host_remote_clear_removes_only_captured_connection_generation() {
	mut app := cross_external_creation_app_fixture()
	mut bridge := app.bridge_context()
	old := &websocket.Client{}
	bridge.register_client('same', old) or { panic('register') }
	owner := bridge.server_authority('same', old) or { panic('owner') }
	lease := cross_host_mirror(mut app, owner, 'stream', 'message')
	bridge.release_wire_stream(owner, upstream.UpstreamSendRequest{
		instance: 'main'
		metadata: {
			'stream_id':         'stream'
			'stream_generation': lease.generation
		}
	})
	assert app.providers.feishu.buffers.len == 0
	assert app.codex_find_stream_targets('stream').len == 0
	next := &websocket.Client{}
	bridge.register_client('same', next) or { panic('register') }
	current := bridge.server_authority('same', next) or { panic('new owner') }
	_ := cross_host_mirror(mut app, current, 'stream', 'message')
	bridge.release_wire_stream(owner, upstream.UpstreamSendRequest{
		instance: 'main'
		metadata: {
			'stream_id':         'stream'
			'stream_generation': lease.generation
		}
	})
	assert app.providers.feishu.buffers['message'].content == 'owned'
	assert app.codex_find_stream_targets('stream').len == 1
}
