module main

import command
import executor as execmod
import feishu
import net
import net.websocket
import time
import upstream.transport

fn bind_transport_pair() (&websocket.Client, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	mut peer := net.dial_tcp((listener.addr() or { panic(err) }).str()) or { panic(err) }
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = listener.accept() or { panic(err) }
	client.set_state(.open)
	return client, peer
}

fn test_bridge_bind_production_adapter_success_clear_malformed_and_connection_replacement() {
	for mode in ['success', 'clear', 'malformed', 'disconnect'] {
		mut app := &App{}
		app.providers.feishu.card_bridge_enabled_flag = true
		app.providers.feishu.card_bridge_ws_url = 'ws://fixture.invalid'
		mut bridge := app.bridge_context()
		mut client, mut peer := bind_transport_pair()
		defer {
			peer.close() or {}
			client.conn.close() or {}
		}
		bridge.set_client_conn(client)
		owner := app.providers.feishu.card_bridge_client_authority or { panic('owner') }
		mut remote := feishu.FeishuState{}
		lease := remote.issue_wire_bind_creation('stream', 'main', 'message') or { panic(err) }
		issue := app.providers.feishu.begin_creation_issue_for_target('stream', 'main', 'message') or { panic(err) }
		app.providers.feishu.complete_bridge_creation_issue(issue, lease, owner) or { panic(err) }
		app.providers.feishu.finish_creation_issue(issue)
		done := chan execmod.WebSocketUpstreamCommandActivity{cap: 1}
		worker := spawn fn [mut app, lease, done] () {
			mut handler := FeishuCommandHandler.new(mut app)
			cmd := transport.WorkerWebSocketUpstreamCommand{
				type_:       'session.bind'
				provider:    'feishu'
				instance:    'main'
				stream_id:   'stream'
				target:      'message'
				target_type: 'message_id'
				metadata:    {
					'creation_generation': lease.generation
					'creation_token':      lease.token
				}
			}
			mut activity := execmod.WebSocketUpstreamCommandActivity{}
			_, _ := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
			done <- activity
		}()
		id := feishu_test_sent_request(mut bridge, mut peer)
		if mode == 'disconnect' {
			bridge.clear_client_conn(client)
			bridge.set_client_conn(&websocket.Client{})
			assert bridge.take_proxy_pending_from(id, client) == none
		} else {
			ch := bridge.take_proxy_pending_from(id, client) or { panic('waiter') }
			if mode == 'clear' {
				app.providers.feishu.mu.@lock()
				released := app.providers.feishu.release_wire_stream_unlocked('message', 'stream', 'main', lease.generation) or { panic('withdraw') }
				app.codex_release_feishu_targets(released)
				ch <- feishu.BridgeProxyResult{ ok: true, stream_generation: 'remote-generation' }
				app.providers.feishu.mu.unlock()
				compensation := feishu_test_sent_request(mut bridge, mut peer)
				response := bridge.take_proxy_pending_from(compensation, client) or { panic('compensation') }
				response <- feishu.BridgeProxyResult{ ok: true }
			} else {
				ch <- feishu.BridgeProxyResult{
					ok:                true
					stream_generation: if mode == 'malformed' {
						''
					} else {
						'remote-generation'
					}
				}
			}
		}
		select {
			activity := <-done {
				if mode == 'success' {
					assert activity.status == 'bound'
					assert app.providers.feishu.buffers['message'].generation == 'remote-generation'
					assert app.codex_find_stream_targets('stream')[0].stream_generation == 'remote-generation'
				} else {
					assert activity.status == 'error'
					assert app.providers.feishu.buffers.len == 0
					assert app.codex_find_stream_targets('stream').len == 0
				}
			}
			3 * time.second {
				panic('bind did not complete')
			}
		}
		worker.wait()
		if mode == 'malformed' {
			assert app.providers.feishu.card_bridge_client_conn == none
		}
		if mode == 'disconnect' {
			assert app.providers.feishu.card_bridge_client_conn != none
		}
	}
}
