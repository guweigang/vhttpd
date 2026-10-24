module main

import codex
import command
import executor as execmod
import feishu
import net
import net.websocket
import time
import upstream.transport

fn update_bridge_pair() (&websocket.Client, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	mut peer := net.dial_tcp((listener.addr() or { panic(err) }).str()) or { panic(err) }
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = listener.accept() or { panic(err) }
	client.set_state(.open)
	return client, peer
}

fn update_bridge_mirror(mut app App, owner &feishu.BridgeAuthority) string {
	app.providers.feishu.register_stream_buffer('message', 'stream', 'main', 'chat', 'chat_id', 'old')
	app.providers.feishu.mu.@lock()
	gen := app.providers.feishu.stream_generation_unlocked('message')
	app.providers.feishu.retain_bridge_binding_unlocked('message', feishu.BridgeBinding{ owner: owner, generation: gen, stream: 'stream', app: 'main' })
	app.providers.feishu.mark_bridge_replica_unlocked('message')
	app.codex_rebind_stream_target('main', 'stream', codex.CodexTarget{ platform: 'feishu', message_id: 'message', buffer_message_id: 'message', stream_generation: gen })
	app.providers.feishu.mu.unlock()
	return gen
}

fn update_bridge_execute(mut app App, generation string) execmod.WebSocketUpstreamCommandActivity {
	mut handler := FeishuCommandHandler.new(mut app)
	cmd := transport.WorkerWebSocketUpstreamCommand{
		type_:        'provider.message.update'
		provider:     'feishu'
		instance:     'main'
		stream_id:    'stream'
		target:       'message'
		target_type:  'message_id'
		message_type: 'interactive'
		content:      '{"elements":[]}'
		metadata:     {
			'stream_generation': generation
		}
	}
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	_, _ := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
	return activity
}

fn test_plain_update_production_bridge_completion_requires_exact_owner_generation_and_message_proof() {
	for mode in ['success', 'rebind', 'clear', 'disconnect', 'missing', 'generation', 'state',
		'target', 'negative', 'error'] {
		mut app := &App{}
		app.providers.feishu.card_bridge_enabled_flag = true
		app.providers.feishu.card_bridge_ws_url = 'ws://fixture.invalid'
		mut bridge := app.bridge_context()
		mut client, mut peer := update_bridge_pair()
		defer {
			peer.close() or {}
			client.conn.close() or {}
		}
		bridge.set_client_conn(client)
		owner := app.providers.feishu.card_bridge_client_authority or { panic('owner') }
		generation := update_bridge_mirror(mut app, owner)
		done := chan execmod.WebSocketUpstreamCommandActivity{cap: 1}
		job := spawn fn [mut app, generation, done] () {
			done <- update_bridge_execute(mut app, generation)
		}()
		id := feishu_test_sent_request(mut bridge, mut peer)
		mut replacement := ''
		if mode == 'disconnect' {
			bridge.clear_client_conn(client)
			bridge.set_client_conn(&websocket.Client{})
			next := app.providers.feishu.card_bridge_client_authority or { panic('next') }
			replacement = update_bridge_mirror(mut app, next)
			assert bridge.take_proxy_pending_from(id, client) == none
		} else {
			ch := bridge.take_proxy_pending_from(id, client) or { panic('pending') }
			app.providers.feishu.mu.@lock()
			if mode == 'clear' {
				released := app.providers.feishu.release_wire_stream_unlocked('message', 'stream', 'main', generation) or { panic('clear') }
				app.codex_release_feishu_targets(released)
			}
			if mode == 'rebind' {
				app.providers.feishu.register_stream_buffer_unlocked('message', 'stream', 'main', '', '', 'replacement')
				replacement = app.providers.feishu.stream_generation_unlocked('message')
				app.codex_rebind_stream_target('main', 'stream', codex.CodexTarget{ platform: 'feishu', message_id: 'message', buffer_message_id: 'message', stream_generation: replacement })
			}
			ch <- feishu.BridgeProxyResult{
				ok:                mode != 'negative'
				message_id:        if mode == 'target' { 'wrong' } else { 'message' }
				stream_generation: if mode == 'missing' {
					''
				} else if mode == 'generation' {
					'wrong'
				} else {
					generation
				}
				stream_state:      if mode == 'state' { 'open' } else { 'message' }
				error:             if mode == 'error' { 'fixture_error' } else { '' }
			}
			app.providers.feishu.mu.unlock()
		}
		select {
			result := <-done {
				if mode == 'success' {
					assert result.status == 'updated' && result.stream_generation == generation
					assert app.providers.feishu.admit_wire_stream_command('message', 'stream', 'main', generation) == none
					assert app.codex_find_stream_targets('stream')[0].stream_generation == generation
				} else {
					assert result.status == 'error'
					if mode in ['rebind', 'disconnect'] {
						assert app.providers.feishu.buffers['message'].generation == replacement
						assert app.providers.feishu.buffers['message'].content in [
							'replacement',
							'old',
						]
						assert app.codex_find_stream_targets('stream')[0].stream_generation == replacement
					} else {
						assert app.providers.feishu.buffers.len == 0
					}
				}
			}
			3 * time.second {
				panic('update completion missing: ${mode}')
			}
		}
		job.wait()
		if mode in ['missing', 'generation', 'state', 'target', 'negative', 'error'] {
			assert bridge.client_conn() == none
		}
	}
}
