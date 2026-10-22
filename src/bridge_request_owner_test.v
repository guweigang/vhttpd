module main

import executor
import feishu
import net.websocket
import net
import time

fn bridge_owner_result(ch chan executor.FeishuCardBridgeResult) executor.FeishuCardBridgeResult {
	select {
		result := <-ch {
			return result
		}
		time.second {
			panic('bridge waiter was not released')
		}
	}
	panic('bridge wait unreachable')
}

fn bridge_owner_proxy_result(ch chan feishu.BridgeProxyResult) feishu.BridgeProxyResult {
	select {
		result := <-ch {
			return result
		}
		time.second {
			panic('proxy waiter was not released')
		}
	}
	panic('proxy wait unreachable')
}

fn test_bridge_requests_require_a_live_connection_registration() {
	mut providers := &ProviderRuntimeHub{}
	mut bridge := providers.feishu_card_bridge_context()
	ch := chan executor.FeishuCardBridgeResult{cap: 1}
	proxy := chan feishu.BridgeProxyResult{cap: 1}
	if _ := bridge.register_pending(ch, 'missing') {
		assert false
	} else {
		assert err.msg() == 'bridge_client_unavailable:missing'
	}
	if _ := bridge.register_proxy_pending(proxy) {
		assert false
	} else {
		assert err.msg() == 'bridge_connection_unavailable'
	}
	assert providers.feishu.card_bridge_request_seq == 0
}

fn test_bridge_result_from_another_connection_cannot_take_waiter() {
	mut providers := &ProviderRuntimeHub{}
	mut bridge := providers.feishu_card_bridge_context()
	client := &websocket.Client{}
	stranger := &websocket.Client{}
	bridge.register_client('owner', client) or { panic('missing') }
	ch := chan executor.FeishuCardBridgeResult{cap: 1}
	id := bridge.register_pending(ch, 'owner') or { panic(err) }
	assert bridge.take_pending_from(id, stranger) == none
	owned := bridge.take_pending_from(id, client) or { panic('wrong connection consumed waiter') }
	owned <- executor.FeishuCardBridgeResult{ body: 'ok' }
	assert bridge_owner_result(ch).body == 'ok'
	assert bridge.take_pending_from(id, client) == none
}

fn test_bridge_disconnect_releases_only_its_own_requests() {
	mut providers := &ProviderRuntimeHub{}
	mut bridge := providers.feishu_card_bridge_context()
	old := &websocket.Client{}
	other := &websocket.Client{}
	bridge.register_client('a', old) or { panic('missing') }
	bridge.register_client('b', other) or { panic('missing') }
	ch := chan executor.FeishuCardBridgeResult{cap: 1}
	keep := chan executor.FeishuCardBridgeResult{cap: 1}
	id := bridge.register_pending(ch, 'a') or { panic(err) }
	keep_id := bridge.register_pending(keep, 'b') or { panic(err) }
	bridge.unregister_client('a', old)
	assert bridge_owner_result(ch).error == 'bridge_connection_closed'
	assert bridge.take_pending(id) == none
	assert bridge.take_pending_from(keep_id, other) != none
	bridge.unregister_client('a', old)
}

fn test_bridge_replacement_cancels_old_request_and_rejects_queued_send() {
	mut providers := &ProviderRuntimeHub{}
	mut bridge := providers.feishu_card_bridge_context()
	old := &websocket.Client{}
	next := &websocket.Client{}
	bridge.register_client('same', old) or { panic('missing') }
	ch := chan executor.FeishuCardBridgeResult{cap: 1}
	id := bridge.register_pending(ch, 'same') or { panic(err) }
	bridge.register_client('same', next) or { panic('missing') }
	assert bridge_owner_result(ch).error == 'bridge_connection_closed'
	assert !bridge.send_pending(id, 'same', 'must not reach replacement')
	current := chan executor.FeishuCardBridgeResult{cap: 1}
	current_id := bridge.register_pending(current, 'same') or { panic(err) }
	bridge.unregister_client('same', old)
	assert bridge.take_pending_from(current_id, old) == none
	assert bridge.take_pending_from(current_id, next) != none
}

fn test_proxy_replacement_releases_old_waiter_and_preserves_new_one() {
	mut providers := &ProviderRuntimeHub{}
	mut bridge := providers.feishu_card_bridge_context()
	old := &websocket.Client{}
	next := &websocket.Client{}
	bridge.set_client_conn(old)
	ch := chan feishu.BridgeProxyResult{cap: 1}
	id := bridge.register_proxy_pending(ch) or { panic(err) }
	bridge.set_client_conn(next)
	result := bridge_owner_proxy_result(ch)
	assert result.request_id == id
	assert result.error == 'bridge_connection_closed'
	assert !bridge.send_proxy_pending(id, 'must not reach replacement')
	current := chan feishu.BridgeProxyResult{cap: 1}
	current_id := bridge.register_proxy_pending(current) or { panic(err) }
	bridge.clear_client_conn(old)
	assert bridge.take_proxy_pending_from(current_id, old) == none
	owned := bridge.take_proxy_pending_from(current_id, next) or { panic('lost replacement waiter') }
	owned <- feishu.BridgeProxyResult{ ok: true }
	assert bridge_owner_proxy_result(current).ok
}

fn test_proxy_disconnect_and_timeout_cleanup_are_idempotent() {
	mut providers := &ProviderRuntimeHub{}
	mut bridge := providers.feishu_card_bridge_context()
	client := &websocket.Client{}
	bridge.set_client_conn(client)
	ch := chan feishu.BridgeProxyResult{cap: 1}
	id := bridge.register_proxy_pending(ch) or { panic(err) }
	assert bridge.take_proxy_pending(id) != none
	bridge.clear_client_conn(client)
	assert providers.feishu.card_bridge_proxy_pending.len == 0
	bridge.set_client_conn(client)
	next := chan feishu.BridgeProxyResult{cap: 1}
	next_id := bridge.register_proxy_pending(next) or { panic(err) }
	assert id != next_id
	bridge.clear_client_conn(client)
	assert bridge_owner_proxy_result(next).error == 'bridge_connection_closed'
	bridge.clear_client_conn(client)
	assert bridge.take_proxy_pending(next_id) == none
}

fn test_bridge_response_and_disconnect_have_one_completion_owner() {
	for _ in 0 .. 64 {
		mut providers := &ProviderRuntimeHub{}
		mut bridge := providers.feishu_card_bridge_context()
		client := &websocket.Client{}
		bridge.register_client('race', client) or { panic('missing') }
		ch := chan executor.FeishuCardBridgeResult{cap: 1}
		id := bridge.register_pending(ch, 'race') or { panic(err) }
		response := spawn fn [mut bridge, client, id] () {
			if result := bridge.take_pending_from(id, client) {
				result <- executor.FeishuCardBridgeResult{ body: 'completed' }
			}
		}()
		disconnect := spawn fn [mut bridge, client] () { bridge.unregister_client('race', client) }()
		response.wait()
		disconnect.wait()
		result := bridge_owner_result(ch)
		assert result.body == 'completed' || result.error == 'bridge_connection_closed'
		assert providers.feishu.card_bridge_pending.len == 0
		select {
			_ := <-ch {
				assert false
			}
			else {
			}
		}
	}
}

fn test_bridge_repeated_registration_of_same_connection_keeps_waiters() {
	mut providers := &ProviderRuntimeHub{}
	mut bridge := providers.feishu_card_bridge_context()
	client := &websocket.Client{}
	sender := bridge.register_client('same', client) or { panic('missing') }
	ch := chan executor.FeishuCardBridgeResult{cap: 1}
	id := bridge.register_pending(ch, 'same') or { panic(err) }
	assert (bridge.register_client('same', client) or { panic('missing') }) == sender
	assert bridge.pending_sender(id, 'same') != none
	assert bridge.take_pending_from(id, client) != none
}

fn test_bridge_registered_write_failure_releases_waiter_in_both_directions() {
	for proxy in [false, true] {
		mut providers := &ProviderRuntimeHub{}
		mut bridge := providers.feishu_card_bridge_context()
		client := &websocket.Client{}
		if proxy {
			bridge.set_client_conn(client)
			ch := chan feishu.BridgeProxyResult{cap: 1}
			id := bridge.register_proxy_pending(ch) or { panic(err) }
			assert !bridge.send_proxy_pending(id, 'closed socket')
			assert bridge_owner_proxy_result(ch).error == 'bridge_connection_closed'
			assert bridge.take_proxy_pending(id) == none
			assert bridge.client_sender('') == none
		} else {
			bridge.register_client('closed', client) or { panic('missing') }
			ch := chan executor.FeishuCardBridgeResult{cap: 1}
			id := bridge.register_pending(ch, 'closed') or { panic(err) }
			assert !bridge.send_pending(id, 'closed', 'closed socket')
			assert bridge_owner_result(ch).error == 'bridge_connection_closed'
			assert bridge.take_pending(id) == none
			assert bridge.client_sender('closed') == none
		}
	}
}

fn test_bridge_registered_send_uses_its_connection_in_both_directions() {
	for proxy in [false, true] {
		mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
		addr := listener.addr() or { panic(err) }
		mut peer := net.dial_tcp(addr.str()) or { panic(err) }
		peer.set_read_timeout(time.second)
		mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
		client.conn = listener.accept() or { panic(err) }
		client.set_state(.open)
		defer {
			peer.close() or {}
			client.close(1000, '') or {}
			listener.close() or {}
		}
		mut providers := &ProviderRuntimeHub{}
		mut bridge := providers.feishu_card_bridge_context()
		if proxy {
			bridge.set_client_conn(client)
			ch := chan feishu.BridgeProxyResult{cap: 1}
			id := bridge.register_proxy_pending(ch) or { panic(err) }
			assert bridge.send_proxy_pending(id, 'registered frame')
			assert bridge.take_proxy_pending_from(id, client) != none
		} else {
			bridge.register_client('connected', client) or { panic('missing') }
			ch := chan executor.FeishuCardBridgeResult{cap: 1}
			id := bridge.register_pending(ch, 'connected') or { panic(err) }
			assert bridge.send_pending(id, 'connected', 'registered frame')
			assert bridge.take_pending_from(id, client) != none
		}
		mut bytes := []u8{len: 128}
		size := peer.read(mut bytes) or { panic(err) }
		assert size > 'registered frame'.len
	}
}
