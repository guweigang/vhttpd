module main

import net
import net.websocket
import time

fn bridge_queue_pair() (&websocket.Client, &net.TcpConn) {
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

fn bridge_queue_publish(mut bridge FeishuCardBridgeContext, outbound bool, client &websocket.Client) {
	if outbound { bridge.set_client_conn(client) } else { bridge.register_client('same', client) }
}

fn bridge_queue_remove(mut bridge FeishuCardBridgeContext, outbound bool, client &websocket.Client) {
	if outbound {
		bridge.clear_client_conn(client)
	} else {
		bridge.unregister_client('same', client)
	}
}

// The test holds the send mutex while the sender enters. The bounded wait checks
// that neither direction can complete before the queue is released.
fn bridge_queue_sender(mut bridge FeishuCardBridgeContext, outbound bool) chan bool {
	entered := chan bool{cap: 1}
	done := chan bool{cap: 1}
	spawn fn [mut bridge, outbound, entered, done] () {
		entered <- true
		done <- if outbound {
			bridge.send_to_server('queued')
		} else {
			bridge.send('same', 'queued')
		}
	}()
	select {
		_ := <-entered {
		}
		time.second {
			panic('sender did not enter')
		}
	}
	select {
		_ := <-done {
			panic('send escaped held queue')
		}
		30 * time.millisecond {
		}
	}
	return done
}

fn bridge_queue_result(done chan bool) bool {
	select {
		value := <-done {
			return value
		}
		2 * time.second {
			panic('queued sender did not finish')
		}
	}
	return false
}

fn test_queued_bridge_send_resolves_replacement_in_both_directions() {
	for outbound in [false, true] {
		mut providers := &ProviderRuntimeHub{}
		mut bridge := providers.feishu_card_bridge_context()
		mut old, mut old_peer := bridge_queue_pair()
		mut next, mut next_peer := bridge_queue_pair()
		defer {
			old.conn.close() or {}
			next.conn.close() or {}
			old_peer.close() or {}
			next_peer.close() or {}
		}
		bridge_queue_publish(mut bridge, outbound, old)
		bridge.state.card_bridge_send_mu.@lock()
		done := bridge_queue_sender(mut bridge, outbound)
		bridge_queue_publish(mut bridge, outbound, next)
		old.set_state(.closed)
		bridge.state.card_bridge_send_mu.unlock()
		assert bridge_queue_result(done)
		mut bytes := []u8{len: 12}
		mut count := 0
		for count < bytes.len {
			n := next_peer.read(mut bytes[count..]) or { panic(err) }
			assert n > 0
			count += n
		}
		assert bytes[..2] == [u8(0x81), 0x86]
		mut payload := []u8{len: 6}
		for i in 0 .. 6 { payload[i] = bytes[6 + i] ^ bytes[2 + i % 4] }
		assert payload.bytestr() == 'queued'
		if outbound {
			assert voidptr(bridge.client_conn() or { panic('replacement removed') }) == voidptr(next)
		} else {
			assert voidptr(bridge.client('same') or { panic('replacement removed') }) == voidptr(next)
		}
	}
}

fn test_queued_bridge_send_rejects_withdrawn_registration_in_both_directions() {
	for outbound in [false, true] {
		mut providers := &ProviderRuntimeHub{}
		mut bridge := providers.feishu_card_bridge_context()
		mut client, mut peer := bridge_queue_pair()
		defer {
			client.conn.close() or {}
			peer.close() or {}
		}
		bridge_queue_publish(mut bridge, outbound, client)
		bridge.state.card_bridge_send_mu.@lock()
		done := bridge_queue_sender(mut bridge, outbound)
		bridge_queue_remove(mut bridge, outbound, client)
		bridge.state.card_bridge_send_mu.unlock()
		assert !bridge_queue_result(done)
		assert client.get_state() == .open
		peer.set_read_timeout(30 * time.millisecond)
		mut bytes := []u8{len: 16}
		if _ := peer.read(mut bytes) { panic('withdrawn connection received a queued write') }
	}
}

fn test_invalid_bridge_sends_do_not_enter_the_send_queue() {
	mut providers := &ProviderRuntimeHub{}
	mut bridge := providers.feishu_card_bridge_context()
	bridge.state.card_bridge_send_mu.@lock()
	defer { bridge.state.card_bridge_send_mu.unlock() }
	assert !bridge.send_to_server('')
	assert !bridge.send('', 'data')
	assert !bridge.send('same', '')
}
