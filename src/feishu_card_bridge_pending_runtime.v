module main

import connection_runtime
import executor
import feishu
import net.websocket

// Caller holds card_bridge_mu. Taking the entry transfers completion ownership;
// channels are buffered by request admission, so teardown never waits for a reader.
fn (mut bridge FeishuCardBridgeContext) cancel_sender_pending_unlocked(sender &connection_runtime.WebSocketSender) {
	mut requests := []string{}
	for id, pending in bridge.state.card_bridge_pending {
		if pending.sender == sender { requests << id }
	}
	for id in requests {
		pending := bridge.state.card_bridge_pending[id] or { continue }
		bridge.state.card_bridge_pending.delete(id)
		pending.ch <- executor.FeishuCardBridgeResult{ error: 'bridge_connection_closed' }
	}
	requests.clear()
	for id, pending in bridge.state.card_bridge_proxy_pending {
		if pending.sender == sender { requests << id }
	}
	for id in requests {
		pending := bridge.state.card_bridge_proxy_pending[id] or { continue }
		bridge.state.card_bridge_proxy_pending.delete(id)
		pending.ch <- feishu.BridgeProxyResult{ request_id: id, error: 'bridge_connection_closed' }
	}
}

fn (mut bridge FeishuCardBridgeContext) take_pending_from(id string, client &websocket.Client) ?chan executor.FeishuCardBridgeResult {
	bridge.state.card_bridge_mu.@lock()
	defer { bridge.state.card_bridge_mu.unlock() }
	pending := bridge.state.card_bridge_pending[id] or { return none }
	if pending.sender.client != client { return none }
	bridge.state.card_bridge_pending.delete(id)
	return pending.ch
}

fn (mut bridge FeishuCardBridgeContext) take_proxy_pending_from(id string, client &websocket.Client) ?chan feishu.BridgeProxyResult {
	bridge.state.card_bridge_mu.@lock()
	defer { bridge.state.card_bridge_mu.unlock() }
	pending := bridge.state.card_bridge_proxy_pending[id] or { return none }
	if pending.sender.client != client { return none }
	bridge.state.card_bridge_proxy_pending.delete(id)
	return pending.ch
}

// Resolve the registered owner after write-queue admission. A replacement must
// never receive a request registered against its predecessor.
fn (mut bridge FeishuCardBridgeContext) pending_sender(id string, client_id string) ?&connection_runtime.WebSocketSender {
	bridge.state.card_bridge_mu.@lock()
	defer { bridge.state.card_bridge_mu.unlock() }
	pending := bridge.state.card_bridge_pending[id] or { return none }
	current := bridge.state.card_bridge_clients[client_id] or { return none }
	if pending.sender != current { return none }
	return current
}

fn (mut bridge FeishuCardBridgeContext) proxy_pending_sender(id string) ?&connection_runtime.WebSocketSender {
	bridge.state.card_bridge_mu.@lock()
	defer { bridge.state.card_bridge_mu.unlock() }
	pending := bridge.state.card_bridge_proxy_pending[id] or { return none }
	current := bridge.state.card_bridge_client_conn or { return none }
	if pending.sender != current { return none }
	return current
}

fn (mut bridge FeishuCardBridgeContext) send_pending(id string, client_id string, payload string) bool {
	if payload == '' { return false }
	bridge.state.card_bridge_send_mu.@lock()
	defer { bridge.state.card_bridge_send_mu.unlock() }
	mut sender := bridge.pending_sender(id, client_id) or { return false }
	sender.write_string(payload) or {
		bridge.unregister_client(client_id, sender.client)
		return false
	}
	return true
}

fn (mut bridge FeishuCardBridgeContext) send_proxy_pending(id string, payload string) bool {
	if payload == '' { return false }
	bridge.state.card_bridge_send_mu.@lock()
	defer { bridge.state.card_bridge_send_mu.unlock() }
	mut sender := bridge.proxy_pending_sender(id) or { return false }
	sender.write_string(payload) or {
		bridge.clear_client_conn(sender.client)
		return false
	}
	return true
}
