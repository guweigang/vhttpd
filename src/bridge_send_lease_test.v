module main

import net
import net.websocket
import time

fn bridge_lease_pair() (&websocket.Client, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	peer.set_read_timeout(time.second)
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = listener.accept() or { panic(err) }
	client.set_state(.open)
	return client, peer
}

fn bridge_lease_wait(ch chan bool) {
	select {
		_ := <-ch {
		}
		3 * time.second {
			panic('bridge lease did not drain')
		}
	}
}

fn test_bridge_replacement_retires_old_lease_owner_and_preserves_new_owner() {
	for outbound in [false, true] {
		mut providers := &ProviderRuntimeHub{}
		mut bridge := providers.feishu_card_bridge_context()
		mut old, mut peer := bridge_lease_pair()
		mut next, mut next_peer := bridge_lease_pair()
		defer {
			peer.close() or {}
			next_peer.close() or {}
			next.close(1000, '') or {}
		}
		key := if outbound { '' } else { 'same' }
		if outbound { bridge.set_client_conn(old) } else { bridge.register_client(key, old) }
		mut owner := bridge.client_sender(key) or { panic('missing owner') }
		entered := chan bool{cap: 1}
		release := chan bool{cap: 1}
		done := chan bool{cap: 1}
		spawn fn [mut owner, entered, release, done] () {
			owner.with_lease(fn [entered, release] (mut writer websocket.Client) ! {
				entered <- true
				_ := <-release
				writer.write_string('old')!
			}) or { panic(err) }
			done <- true
		}()
		bridge_lease_wait(entered)
		if outbound { bridge.set_client_conn(next) } else { bridge.register_client(key, next) }
		mut replacement := bridge.client_sender(key) or { panic('replacement missing') }
		assert voidptr(owner) != voidptr(replacement)
		if _ := owner.write_string('late') {
			assert false
		} else {
			assert err.msg() == 'websocket_sender_retired'
		}
		// Stale reader callbacks must not retire the new writer generation.
		if outbound { bridge.clear_client_conn(old) } else { bridge.unregister_client(key, old) }
		assert if outbound { bridge.send_to_server('new') } else { bridge.send(key, 'new') }
		closed := chan bool{cap: 1}
		spawn fn [mut old, closed] () {
			old.close(1000, '') or { panic(err) }
			closed <- true
		}()
		select {
			_ := <-closed {
				panic('native close escaped active lease')
			}
			20 * time.millisecond {
			}
		}
		release <- true
		bridge_lease_wait(done)
		bridge_lease_wait(closed)
		owner.wait_idle()
		assert voidptr((bridge.client_sender(key) or { panic('replacement lost') }).client) == voidptr(next)
	}
}

fn test_bridge_withdrawal_closes_admission_before_native_connection_release() {
	for outbound in [false, true] {
		mut providers := &ProviderRuntimeHub{}
		mut bridge := providers.feishu_card_bridge_context()
		mut client, mut peer := bridge_lease_pair()
		defer {
			peer.close() or {}
			client.close(1000, '') or {}
		}
		key := if outbound { '' } else { 'same' }
		if outbound { bridge.set_client_conn(client) } else { bridge.register_client(key, client) }
		mut owner := bridge.client_sender(key) or { panic('owner missing') }
		if outbound {
			bridge.clear_client_conn(client)
		} else {
			bridge.unregister_client(key, client)
		}
		assert bridge.client_sender(key) == none
		if _ := owner.write_string('late') {
			assert false
		} else {
			assert err.msg() == 'websocket_sender_retired'
		}
		owner.wait_idle()
		assert client.get_state() == .open
	}
}

fn test_bridge_callback_replies_share_the_registered_owner_and_reject_retired_generation() {
	for outbound in [false, true] {
		mut app := &App{}
		mut bridge := app.providers.feishu_card_bridge_context()
		mut client, mut peer := bridge_lease_pair()
		mut next, mut next_peer := bridge_lease_pair()
		defer {
			peer.close() or {}
			next_peer.close() or {}
			client.close(1000, '') or {}
			next.close(1000, '') or {}
		}
		key := if outbound { '' } else { 'same' }
		owner := if outbound {
			bridge.set_client_conn(client)
		} else {
			bridge.register_client(key, client) or { panic('no registration') }
		}
		mut outgoing := &FeishuCardBridgeClientState{ host: app, bridge: bridge, sender: owner }
		mut accepted := &FeishuCardBridgeServerState{ host: app, bridge: bridge, client_id: key, client: client, sender: owner }
		assert voidptr(outgoing.sender or { panic('missing upstream owner') }) == voidptr(bridge.client_sender(key) or { panic('missing registry owner') })
		assert voidptr(accepted.sender or { panic('missing server owner') }) == voidptr(owner)
		if outbound {
			outgoing.reply('reply') or { panic(err) }
		} else {
			accepted.reply('reply') or { panic(err) }
		}
		if outbound { bridge.set_client_conn(next) } else { bridge.register_client(key, next) }
		if outbound {
			if _ := outgoing.reply('late') {
				assert false
			} else {
				assert err.msg() == 'websocket_sender_retired'
			}
			bridge.clear_client_conn(client)
			assert bridge.client('') == none
		} else {
			if _ := accepted.reply('late') {
				assert false
			} else {
				assert err.msg() == 'websocket_sender_retired'
			}
			accepted.release_client()
			if _ := accepted.reply('released') {
				assert false
			} else {
				assert err.msg() == 'bridge_connection_unavailable'
			}
		}
		assert voidptr((bridge.client_sender(key) or { panic('replacement removed') }).client) == voidptr(next)
	}
}
