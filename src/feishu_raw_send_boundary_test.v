module main

import command
import config
import executor as execmod
import feishu
import provider
import net
import net.websocket
import time
import upstream.transport

fn raw_send_app() &App {
	mut app := &App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				enabled:        true
				apps:           {
					'main': config.FeishuAppConfig{ app_id: 'cli', app_secret: 'secret' }
				}
				http_test_stub: true
			}
		}
	}
	app.register_provider_spec(ProviderSpec{
		lifecycle_ctx: provider.RuntimeContext.noop()
		name:          'feishu'
		enabled:       true
		has_handler:   true
		has_runtime:   true
		route_kind:    .feishu
		provider:      FeishuProvider{}
		handler:       FeishuCommandHandler.new(mut app)
		runtime:       NoopProviderRuntime{}
	})
	return app
}

fn raw_send_packet(lease feishu.CreationLease) transport.WorkerWebSocketUpstreamCommand {
	return transport.WorkerWebSocketUpstreamCommand{
		type_:       'provider.message.send'
		provider:    'feishu'
		instance:    'main'
		stream_id:   'stream'
		target:      'chat'
		target_type: 'chat_id'
		text:        'old'
		metadata:    {
			'stream_generation': lease.generation
			'creation_token':    lease.token
		}
	}
}

fn raw_send_execute(mut app App, cmd transport.WorkerWebSocketUpstreamCommand) execmod.WebSocketUpstreamCommandActivity {
	mut handler := FeishuCommandHandler.new(mut app)
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	_, _ := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
	return activity
}

fn test_raw_send_executor_rejects_missing_scope_credentials_and_generic_transport_fallback() {
	for cmd in [
		transport.WorkerWebSocketUpstreamCommand{ type_: 'provider.message.send', provider: 'feishu', target: 'chat', text: 'late' },
		transport.WorkerWebSocketUpstreamCommand{ type_: 'feishu.message.send', target: 'chat', text: 'late' },
		transport.WorkerWebSocketUpstreamCommand{ type_: 'provider.message.send', provider: 'feishu', stream_id: ' ', target: 'chat', text: 'late' },
		transport.WorkerWebSocketUpstreamCommand{ type_: 'provider.message.send', provider: 'feishu', stream_id: 'stream', target: 'chat', text: 'late' },
		transport.WorkerWebSocketUpstreamCommand{ event: 'send', target: 'chat', text: 'late' },
		transport.WorkerWebSocketUpstreamCommand{ type_: 'codex.message.send', target: 'thread', text: 'late' },
		transport.WorkerWebSocketUpstreamCommand{ type_: 'provider.message.send', provider: 'codex', target: 'thread', text: 'late' },
	] {
		mut app := raw_send_app()
		activities, err := app.execute_command_envelopes_with_snapshots('raw-send', DispatchContext{}, [cmd])
		assert err != ''
		assert activities.len == 1
		assert activities[0].status == 'error'
		assert app.providers.feishu.http_test_calls == 0
		assert app.providers.feishu.buffers.len == 0
	}
}

fn test_raw_send_revoked_or_spent_command_cannot_replay_by_stripping_stream() {
	mut app := raw_send_app()
	lease := app.providers.feishu.issue_wire_creation('stream', 'main') or { panic(err) }
	packet := raw_send_packet(lease)
	result := raw_send_execute(mut app, packet)
	assert result.status == 'sent' && result.stream_generation == lease.generation
	app.providers.feishu.clear_stream_buffers('stream')
	calls := app.providers.feishu.http_test_calls
	for cmd in [packet, transport.WorkerWebSocketUpstreamCommand{ ...packet, stream_id: '' },
		transport.WorkerWebSocketUpstreamCommand{ ...packet, stream_id: '', metadata: map[string]string{} }] {
		assert raw_send_execute(mut app, cmd).status == 'error'
	}
	assert calls > 0 && app.providers.feishu.http_test_calls == calls
	assert app.providers.feishu.buffers.len == 0
}

fn raw_send_pair() (&websocket.Client, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	mut peer := net.dial_tcp((listener.addr() or { panic(err) }).str()) or { panic(err) }
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = listener.accept() or { panic(err) }
	client.set_state(.open)
	return client, peer
}

fn test_raw_send_bridge_confirmation_requires_issued_generation_and_live_publication() {
	for mode in ['success', 'missing', 'generation', 'empty_id', 'negative', 'rebind', 'clear',
		'disconnect'] {
		mut app := raw_send_app()
		app.providers.feishu.card_bridge_enabled_flag = true
		app.providers.feishu.card_bridge_ws_url = 'ws://fixture'
		mut bridge := app.providers.feishu_card_bridge_context()
		client, mut peer := raw_send_pair()
		defer {
			peer.close() or {}
			client.close(1000, 'fixture done') or {}
		}
		bridge.set_client_conn(client)
		mut owner := app.providers.feishu.card_bridge_client_authority or { panic('owner') }
		lease := app.providers.feishu.issue_bridge_creation(mut owner, 'stream', 'main', '', 'issue') or { panic(err) }
		packet := raw_send_packet(lease)
		done := chan execmod.WebSocketUpstreamCommandActivity{cap: 1}
		job := spawn fn [mut app, packet, done] () { done <- raw_send_execute(mut app, packet) }()
		id := feishu_test_sent_request(mut bridge, mut peer)
		if mode == 'disconnect' {
			bridge.clear_client_conn(client)
			bridge.set_client_conn(&websocket.Client{})
			app.providers.feishu.register_stream_buffer('late', 'stream', 'main', '', '', 'replacement')
		} else {
			ch := bridge.take_proxy_pending_from(id, client) or { panic('pending') }
			if mode == 'clear' { app.providers.feishu.clear_stream_buffers('stream') }
			if mode == 'rebind' {
				app.providers.feishu.register_stream_buffer('late', 'stream', 'main', '', '', 'replacement')
			}
			ch <- feishu.BridgeProxyResult{
				ok:                mode != 'negative'
				message_id:        if mode == 'empty_id' {
					''
				} else {
					'late'
				}
				stream_generation: if mode == 'missing' {
					''
				} else if mode == 'generation' {
					'wrong'
				} else {
					lease.generation
				}
			}
		}
		select {
			result := <-done {
				expected_status := if mode == 'success' { 'sent' } else { 'error' }
				assert result.status == expected_status
				if mode in ['rebind', 'disconnect'] {
					assert app.providers.feishu.buffers['late'].content == 'replacement'
					assert app.providers.feishu.buffers['late'].generation != lease.generation
				} else if mode == 'success' {
					assert app.providers.feishu.buffers['late'].generation == lease.generation
				} else {
					assert app.providers.feishu.buffers.len == 0
				}
				if mode in ['missing', 'generation', 'empty_id', 'negative'] {
					assert app.providers.feishu.card_bridge_client_conn == none
				}
			}
			3 * time.second {
				panic('send completion missing: ' + mode)
			}
		}
		job.wait()
	}
}
