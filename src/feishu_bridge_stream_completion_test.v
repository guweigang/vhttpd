module main

import codex
import command
import config
import executor as execmod
import feishu
import net
import net.websocket
import time
import upstream.transport

fn completion_pair() (&websocket.Client, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	mut peer := net.dial_tcp((listener.addr() or { panic(err) }).str()) or { panic(err) }
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = listener.accept() or { panic(err) }
	client.set_state(.open)
	return client, peer
}

fn completion_mirror(mut app App, owner &feishu.BridgeAuthority) string {
	mut remote := feishu.FeishuState{}
	lease := remote.issue_wire_creation('stream', 'main') or { panic(err) }
	issue := app.providers.feishu.begin_creation_issue('stream', 'main') or { panic(err) }
	app.providers.feishu.complete_bridge_creation_issue(issue, lease, owner) or { panic(err) }
	app.providers.feishu.finish_creation_issue(issue)
	claim := app.providers.feishu.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) or { panic('initial') }
	app.providers.feishu.mu.@lock()
	assert app.providers.feishu.commit_initial_send_generation_unlocked(claim, 'message', 'main', 'chat', 'chat_id', 'old', lease.generation)
	app.codex_rebind_stream_target('main', 'stream', codex.CodexTarget{ platform: 'feishu', message_id: 'message', buffer_message_id: 'message', stream_generation: lease.generation })
	app.providers.feishu.mu.unlock()
	app.providers.feishu.finish_initial_send(claim)
	return lease.generation
}

fn completion_execute(mut app App, action string, generation string) execmod.WebSocketUpstreamCommandActivity {
	mut handler := FeishuCommandHandler.new(mut app)
	cmd := transport.WorkerWebSocketUpstreamCommand{
		message_type: 'interactive'
		type_:        'stream.${action}'
		provider:     'feishu'
		instance:     'main'
		stream_id:    'stream'
		target:       'message'
		target_type:  'message_id'
		text:         'delta'
		content:      if action == 'fail' {
			feishu.SendMessageRequest.interactive_markdown_card('failed')
		} else {
			''
		}
		metadata:     {
			'stream_generation': generation
			'finish':            'true'
		}
	}
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	_, _ := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
	return activity
}

fn test_bridge_stream_production_completion_matrix_preserves_exact_owner_and_generation() {
	for action in ['append', 'finish', 'fail'] {
		for mode in ['ok', 'clear', 'rebind', 'disconnect', 'bad-generation', 'bad-state', 'non-ok',
			'missing-proof'] {
			mut app := &App{}
			app.providers.feishu.card_bridge_enabled_flag = true
			app.providers.feishu.card_bridge_ws_url = 'ws://fixture.invalid'
			mut bridge := app.bridge_context()
			mut client, mut peer := completion_pair()
			defer {
				peer.close() or {}
				client.conn.close() or {}
			}
			bridge.set_client_conn(client)
			owner := app.providers.feishu.card_bridge_client_authority or { panic('owner') }
			generation := completion_mirror(mut app, owner)
			done := chan execmod.WebSocketUpstreamCommandActivity{cap: 1}
			worker := spawn fn [mut app, action, generation, done] () {
				done <- completion_execute(mut app, action, generation)
			}()
			id := feishu_test_sent_request(mut bridge, mut peer)

			mut replacement := ''
			if mode == 'disconnect' {
				bridge.clear_client_conn(client)
				bridge.set_client_conn(&websocket.Client{})
				next := app.providers.feishu.card_bridge_client_authority or { panic('replacement') }
				replacement = completion_mirror(mut app, next)
				assert bridge.take_proxy_pending_from(id, client) == none
			} else {
				response := bridge.take_proxy_pending_from(id, client) or { panic('waiter') }
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
				response <- feishu.BridgeProxyResult{
					ok:                mode != 'non-ok'
					message_id:        'message'
					stream_generation: if mode == 'missing-proof' {
						''
					} else if mode == 'bad-generation' {
						'wrong'
					} else {
						generation
					}
					stream_state:      if mode == 'bad-state' {
						if action == 'fail' { 'open' } else { 'removed' }
					} else if action == 'fail' {
						'removed'
					} else if action == 'finish' {
						'sealed'
					} else {
						'open'
					}
				}
				app.providers.feishu.mu.unlock()
				if mode in ['clear', 'rebind'] {
					compensation := feishu_test_sent_request(mut bridge, mut peer)
					ack := bridge.take_proxy_pending_from(compensation, client) or { panic('compensation') }
					ack <- feishu.BridgeProxyResult{ ok: true }
				}
			}
			select {
				activity := <-done {
					if mode == 'ok' {
						assert activity.error == ''
						assert activity.stream_generation == generation
						if action == 'fail' {
							assert app.providers.feishu.buffers.len == 0 && app.codex_find_stream_targets('stream').len == 0
						} else {
							assert app.providers.feishu.buffers['message'].sealed == (action == 'finish')
						}
					} else {
						assert activity.status == 'error'
						if mode in ['rebind', 'disconnect'] {
							assert app.providers.feishu.buffers['message'].generation == replacement
							assert !app.providers.feishu.buffers['message'].sealed
							assert app.codex_find_stream_targets('stream')[0].stream_generation == replacement
						} else {
							assert app.providers.feishu.buffers.len == 0 && app.codex_find_stream_targets('stream').len == 0
						}
					}
				}
				3 * time.second {
					panic('completion did not finish')
				}
			}
			worker.wait()
			if mode in ['bad-generation', 'bad-state', 'non-ok', 'missing-proof'] {
				assert bridge.client_conn() == none
			}
			if mode == 'disconnect' {
				assert bridge.client_conn() != none
			}
		}
	}
}

fn test_native_fail_completion_withdraws_paired_targets_and_preserves_peer() {
	mut app := &App{}
	app.providers.feishu.http_test_stub = true
	app.providers.feishu.enabled = true
	app.providers.feishu.open_base_url = 'https://open.feishu.test/open-apis'
	app.providers.feishu.apps['main'] = config.FeishuAppConfig{ app_id: 'fixture', app_secret: 'secret' }
	app.providers.feishu.register_stream_buffer('message', 'stream', 'main', 'chat', 'chat_id', 'old')
	generation := app.providers.feishu.buffers['message'].generation
	app.codex_add_stream_target('main', 'stream', codex.CodexTarget{ platform: 'feishu', message_id: 'message', buffer_message_id: 'message', stream_generation: generation })
	app.codex_add_stream_target('main', 'stream', codex.CodexTarget{ platform: 'feishu', message_id: 'segment', buffer_message_id: 'message', stream_generation: generation })
	app.codex_add_stream_target('main', 'stream', codex.CodexTarget{ platform: 'other', message_id: 'message' })
	activity := completion_execute(mut app, 'fail', generation)
	assert activity.status == 'failed'
	assert app.providers.feishu.buffers.len == 0
	targets := app.codex_find_stream_targets('stream')
	assert targets.len == 1 && targets[0].platform == 'other'
}

fn test_empty_finish_seals_current_buffer_without_http_and_preserves_generation() {
	mut app := &App{}
	app.providers.feishu.register_stream_buffer('message', 'stream', 'main', '', '', '')
	generation := app.providers.feishu.buffers['message'].generation
	activity := completion_execute(mut app, 'finish', generation)
	assert activity.status == 'finished'
	assert app.providers.feishu.buffers['message'].sealed
	assert app.providers.feishu.buffers['message'].generation == generation
	assert app.providers.feishu.http_test_calls == 0
}

fn test_bridge_stream_concurrent_appends_queue_without_changing_captured_generation() {
	mut app := &App{}
	app.providers.feishu.card_bridge_enabled_flag = true
	app.providers.feishu.card_bridge_ws_url = 'ws://fixture.invalid'
	mut bridge := app.bridge_context()
	mut client, mut peer := completion_pair()
	defer {
		peer.close() or {}
		client.conn.close() or {}
	}
	bridge.set_client_conn(client)
	owner := app.providers.feishu.card_bridge_client_authority or { panic('owner') }
	generation := completion_mirror(mut app, owner)
	done := chan execmod.WebSocketUpstreamCommandActivity{cap: 2}
	first := spawn fn [mut app, generation, done] () {
		done <- completion_execute(mut app, 'append', generation)
	}()
	id := feishu_test_sent_request(mut bridge, mut peer)
	started := chan bool{cap: 1}
	second := spawn fn [mut app, generation, done, started] () {
		started <- true
		done <- completion_execute(mut app, 'append', generation)
	}()
	_ = <-started
	select {
		_ := <-done {
			panic('queued append escaped')
		}
		25 * time.millisecond {
		}
	}
	bridge.state.card_bridge_mu.@lock()
	assert bridge.state.card_bridge_proxy_pending.len == 1
	bridge.state.card_bridge_mu.unlock()
	response := bridge.take_proxy_pending_from(id, client) or { panic('first') }
	response <- feishu.BridgeProxyResult{ ok: true, message_id: 'message', stream_generation: generation, stream_state: 'open' }
	next := feishu_test_sent_request(mut bridge, mut peer)
	assert next != id
	ack := bridge.take_proxy_pending_from(next, client) or { panic('next') }
	ack <- feishu.BridgeProxyResult{ ok: true, message_id: 'message', stream_generation: generation, stream_state: 'open' }
	for _ in 0 .. 2 {
		select {
			activity := <-done {
				assert activity.status == 'buffered' && activity.stream_generation == generation
			}
			3 * time.second {
				panic('queued append stuck')
			}
		}
	}
	first.wait()
	second.wait()
}

fn test_bridge_stream_operation_rejects_unowned_native_buffer_before_mutating_it() {
	for action in ['append', 'finish', 'fail'] {
		mut app := &App{}
		app.providers.feishu.card_bridge_enabled_flag = true
		app.providers.feishu.card_bridge_ws_url = 'ws://fixture.invalid'
		app.providers.feishu.register_stream_buffer('message', 'stream', 'main', '', '', 'native')
		generation := app.providers.feishu.buffers['message'].generation
		app.codex_add_stream_target('main', 'stream', codex.CodexTarget{ platform: 'feishu', message_id: 'message', buffer_message_id: 'message', stream_generation: generation })
		activity := completion_execute(mut app, action, generation)
		assert activity.status == 'error'
		assert app.providers.feishu.buffers['message'].generation == generation
		assert app.providers.feishu.buffers['message'].content == 'native'
		assert !app.providers.feishu.buffers['message'].sealed
		assert app.codex_find_stream_targets('stream')[0].stream_generation == generation
		assert app.providers.feishu.card_bridge_proxy_pending.len == 0
		assert app.providers.feishu.http_test_calls == 0
	}
}
