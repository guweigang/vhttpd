module main

import executor
import feishu
import time
import net.websocket

fn test_bridge_pending_cleanup_cannot_remove_later_registration() {
	mut providers := &ProviderRuntimeHub{}
	mut setup := providers.feishu_card_bridge_context()
	client_owner := &websocket.Client{}
	setup.register_client('test', client_owner) or { panic('missing') }
	setup.set_client_conn(client_owner)
	mut bridge := providers.feishu_card_bridge_context()
	first := chan executor.FeishuCardBridgeResult{cap: 1}
	second := chan executor.FeishuCardBridgeResult{cap: 1}
	old_id := bridge.register_pending(first, 'test') or { panic(err) }
	new_id := bridge.register_pending(second, 'test') or { panic(err) }
	assert old_id != new_id
	old := bridge.take_pending(old_id) or { panic('first missing') }
	old <- executor.FeishuCardBridgeResult{ body: 'first' }
	assert bridge.take_pending(old_id) == none
	current := bridge.take_pending(new_id) or { panic('second removed by old cleanup') }
	current <- executor.FeishuCardBridgeResult{ body: 'second' }
	assert (<-first).body == 'first'
	assert (<-second).body == 'second'
	assert providers.feishu.card_bridge_pending.len == 0
}

fn test_bridge_proxy_pending_cleanup_cannot_remove_later_registration() {
	mut providers := &ProviderRuntimeHub{}
	mut setup := providers.feishu_card_bridge_context()
	client_owner := &websocket.Client{}
	setup.register_client('test', client_owner) or { panic('missing') }
	setup.set_client_conn(client_owner)
	mut bridge := providers.feishu_card_bridge_context()
	first := chan feishu.BridgeProxyResult{cap: 1}
	second := chan feishu.BridgeProxyResult{cap: 1}
	old_id := bridge.register_proxy_pending(first) or { panic(err) }
	new_id := bridge.register_proxy_pending(second) or { panic(err) }
	assert old_id != new_id
	old := bridge.take_proxy_pending(old_id) or { panic('first missing') }
	old <- feishu.BridgeProxyResult{ message_id: 'first' }
	assert bridge.take_proxy_pending(old_id) == none
	current := bridge.take_proxy_pending(new_id) or { panic('second removed by old cleanup') }
	current <- feishu.BridgeProxyResult{ message_id: 'second' }
	assert (<-first).message_id == 'first'
	assert (<-second).message_id == 'second'
	assert providers.feishu.card_bridge_proxy_pending.len == 0
}

fn test_bridge_concurrent_contexts_share_pending_registration_owner() {
	mut providers := &ProviderRuntimeHub{}
	mut setup := providers.feishu_card_bridge_context()
	client_owner := &websocket.Client{}
	setup.register_client('test', client_owner) or { panic('missing') }
	setup.set_client_conn(client_owner)
	ids := chan string{cap: 64}
	mut tasks := []thread{}
	for _ in 0 .. 64 {
		mut bridge := providers.feishu_card_bridge_context()
		tasks << spawn fn [mut bridge, ids] () {
			for _ in 0 .. 32 {
				ch := chan executor.FeishuCardBridgeResult{cap: 1}
				id := bridge.register_pending(ch, 'test') or { panic(err) }
				ids <- id
				proxy := chan feishu.BridgeProxyResult{cap: 1}
				proxy_id := bridge.register_proxy_pending(proxy) or { panic(err) }
				ids <- proxy_id
			}
		}()
	}
	mut seen := map[string]bool{}
	for _ in 0 .. 4096 {
		mut id := ''
		select {
			value := <-ids {
				id = value
			}
			5 * time.second {
				panic('concurrent registration stalled')
			}
		}
		assert id !in seen
		seen[id] = true
	}
	tasks.wait()
	assert providers.feishu.card_bridge_request_seq == 4096
	assert providers.feishu.card_bridge_pending.len == 2048
	assert providers.feishu.card_bridge_proxy_pending.len == 2048
	mut bridge := providers.feishu_card_bridge_context()
	for id, _ in seen {
		if id.starts_with('bridge-proxy-') {
			assert bridge.take_proxy_pending(id) != none
			assert bridge.take_proxy_pending(id) == none
		} else {
			assert bridge.take_pending(id) != none
			assert bridge.take_pending(id) == none
		}
	}
	assert providers.feishu.card_bridge_pending.len == 0
	assert providers.feishu.card_bridge_proxy_pending.len == 0
}

fn test_bridge_request_sequence_exhaustion_rejects_without_overwrite() {
	mut providers := &ProviderRuntimeHub{}
	mut setup := providers.feishu_card_bridge_context()
	client_owner := &websocket.Client{}
	setup.register_client('test', client_owner) or { panic('missing') }
	setup.set_client_conn(client_owner)
	providers.feishu.card_bridge_request_seq = u64(0xfffffffffffffffe)
	mut bridge := providers.feishu_card_bridge_context()
	ch := chan executor.FeishuCardBridgeResult{cap: 1}
	id := bridge.register_pending(ch, 'test') or { panic(err) }
	if _ := bridge.register_pending(ch, 'test') {
		assert false
	} else {
		assert err.msg() == 'bridge_request_id_exhausted'
	}
	proxy := chan feishu.BridgeProxyResult{cap: 1}
	if _ := bridge.register_proxy_pending(proxy) {
		assert false
	} else {
		assert err.msg() == 'bridge_request_id_exhausted'
	}
	assert providers.feishu.card_bridge_request_seq == u64(0xffffffffffffffff)
	assert bridge.take_pending(id) != none
	assert providers.feishu.card_bridge_proxy_pending.len == 0
}
