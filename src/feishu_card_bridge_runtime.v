module main

import executor
import connection_runtime
import json2 as json
import log
import net.websocket
import os
import time
import upstream
import feishu

struct FeishuCardBridgeRuntime {}

struct FeishuCardBridgeContext {
mut:
	state &feishu.FeishuState @[required]
}

fn (mut providers ProviderRuntimeHub) feishu_card_bridge_context() FeishuCardBridgeContext {
	return FeishuCardBridgeContext{
		state: &providers.feishu
	}
}

fn FeishuCardBridgeRuntime.default_client_id() string {
	host := (os.hostname() or { '' }).trim_space()
	if host != '' {
		return host
	}
	return 'local-main'
}

fn (mut providers ProviderRuntimeHub) feishu_card_bridge_apply_env_fallbacks() {
	if providers.feishu.card_bridge_ws_url.trim_space() == '' {
		providers.feishu.card_bridge_ws_url = os.getenv('VHTTPD_FEISHU_CARD_BRIDGE_WS_URL').trim_space()
	}
	if providers.feishu.card_bridge_client_id.trim_space() == '' {
		providers.feishu.card_bridge_client_id =
			os.getenv('VHTTPD_FEISHU_CARD_BRIDGE_CLIENT_ID').trim_space()
	}
	if providers.feishu.card_bridge_client_id.trim_space() == '' {
		providers.feishu.card_bridge_client_id = FeishuCardBridgeRuntime.default_client_id()
	}
	if providers.feishu.card_bridge_token.trim_space() == '' {
		providers.feishu.card_bridge_token = os.getenv('VHTTPD_FEISHU_CARD_BRIDGE_TOKEN').trim_space()
	}
	if providers.feishu.card_bridge_target_id.trim_space() == '' {
		providers.feishu.card_bridge_target_id =
			os.getenv('VHTTPD_FEISHU_CARD_BRIDGE_TARGET_ID').trim_space()
	}
	if providers.feishu.card_bridge_target_id == '' {
		providers.feishu.card_bridge_target_id = providers.feishu.card_bridge_client_id
	}
}

fn (providers &ProviderRuntimeHub) feishu_card_bridge_enabled() bool {
	return providers.feishu.card_bridge_enabled_flag && providers.feishu.card_bridge_ws_url.trim_space() != ''
}

fn (mut bridge FeishuCardBridgeContext) set_client_conn(client &websocket.Client) &connection_runtime.WebSocketSender {
	bridge.state.card_bridge_mu.@lock()
	defer { bridge.state.card_bridge_mu.unlock() }
	if mut current := bridge.state.card_bridge_client_conn {
		if voidptr(current.client) == voidptr(client) { return current }
		current.retire()
		bridge.cancel_sender_pending_unlocked(current)
	}
	owner := connection_runtime.WebSocketSender.new(client)
	bridge.state.card_bridge_client_conn = owner
	return owner
}

fn (mut bridge FeishuCardBridgeContext) clear_client_conn(client &websocket.Client) {
	bridge.state.card_bridge_mu.@lock()
	defer { bridge.state.card_bridge_mu.unlock() }
	if mut current := bridge.state.card_bridge_client_conn {
		if voidptr(current.client) == voidptr(client) {
			current.retire()
			bridge.cancel_sender_pending_unlocked(current)
			bridge.state.card_bridge_client_conn = none
		}
	}
}

// These raw-client getters are observations only; asynchronous sends borrow the owner.
fn (mut bridge FeishuCardBridgeContext) client_conn() ?&websocket.Client {
	owner := bridge.client_sender('') or { return none }
	return owner.client
}

fn (mut bridge FeishuCardBridgeContext) client(client_id string) ?&websocket.Client {
	if client_id == '' { return none }
	owner := bridge.client_sender(client_id) or { return none }
	return owner.client
}

fn (mut bridge FeishuCardBridgeContext) client_sender(client_id string) ?&connection_runtime.WebSocketSender {
	bridge.state.card_bridge_mu.@lock()
	defer { bridge.state.card_bridge_mu.unlock() }
	if client_id == '' { return bridge.state.card_bridge_client_conn }
	return bridge.state.card_bridge_clients[client_id] or { return none }
}

fn (mut bridge FeishuCardBridgeContext) send_to_server(payload string) bool {
	if payload == '' {
		return false
	}
	bridge.state.card_bridge_send_mu.@lock()
	defer {
		bridge.state.card_bridge_send_mu.unlock()
	}
	// Resolve after queue admission: a reconnect may replace the borrowed client
	// while this sender waits for an earlier write to finish.
	mut sender := bridge.client_sender('') or { return false }
	sender.write_string(payload) or {
		log.error('[bridge] ❌ send to server failed: ${err}')
		bridge.clear_client_conn(sender.client)
		return false
	}
	return true
}

fn (mut bridge FeishuCardBridgeContext) register_client(client_id string, client &websocket.Client) ?&connection_runtime.WebSocketSender {
	if client_id == '' { return none }
	bridge.state.card_bridge_mu.@lock()
	if mut current := bridge.state.card_bridge_clients[client_id] {
		if voidptr(current.client) == voidptr(client) {
			bridge.state.card_bridge_mu.unlock()
			return current
		}
		current.retire()
		bridge.cancel_sender_pending_unlocked(current)
	}
	owner := connection_runtime.WebSocketSender.new(client)
	bridge.state.card_bridge_clients[client_id] = owner
	bridge.state.card_bridge_mu.unlock()
	log.info('[bridge] ✅ feishu card bridge client connected: ${client_id}')
	return owner
}

// Withdrawal closes owner admission; stale callbacks cannot retire a replacement.
fn (mut bridge FeishuCardBridgeContext) unregister_client(client_id string, client &websocket.Client) {
	if client_id == '' { return }
	bridge.state.card_bridge_mu.@lock()
	mut current := bridge.state.card_bridge_clients[client_id] or {
		bridge.state.card_bridge_mu.unlock()
		return
	}
	if voidptr(current.client) != voidptr(client) {
		bridge.state.card_bridge_mu.unlock()
		return
	}
	current.retire()
	bridge.cancel_sender_pending_unlocked(current)
	bridge.state.card_bridge_clients.delete(client_id)
	bridge.state.card_bridge_mu.unlock()
	log.info('[bridge] ℹ️ feishu card bridge client disconnected: ${client_id}')
}

fn (mut bridge FeishuCardBridgeContext) has_client(client_id string) bool {
	if client_id == '' {
		return false
	}
	bridge.state.card_bridge_mu.@lock()
	defer {
		bridge.state.card_bridge_mu.unlock()
	}
	return client_id in bridge.state.card_bridge_clients
}

fn (mut bridge FeishuCardBridgeContext) send(client_id string, payload string) bool {
	if client_id == '' || payload == '' {
		return false
	}
	bridge.state.card_bridge_send_mu.@lock()
	defer {
		bridge.state.card_bridge_send_mu.unlock()
	}
	// Registry removal or reconnect while queued must invalidate the old borrow.
	mut sender := bridge.client_sender(client_id) or { return false }
	sender.write_string(payload) or {
		log.error('[bridge] ❌ send failed client=${client_id}: ${err}')
		bridge.unregister_client(client_id, sender.client)
		return false
	}
	return true
}

// Both request directions allocate and publish under the state owner's mutex.
// Wall-clock timestamps are correlation data, not unique registration identities.
fn (mut bridge FeishuCardBridgeContext) register_pending(ch chan executor.FeishuCardBridgeResult, client_id string) !string {
	bridge.state.card_bridge_mu.@lock()
	defer { bridge.state.card_bridge_mu.unlock() }
	sender := bridge.state.card_bridge_clients[client_id] or { return error('bridge_client_unavailable:${client_id}') }
	if bridge.state.card_bridge_request_seq == u64(0xffffffffffffffff) {
		return error('bridge_request_id_exhausted')
	}
	bridge.state.card_bridge_request_seq++
	request_id := 'bridge-${bridge.state.card_bridge_request_seq}'
	bridge.state.card_bridge_pending[request_id] = feishu.CardBridgePending{ sender: sender, ch: ch }
	return request_id
}

fn (mut bridge FeishuCardBridgeContext) take_pending(request_id string) ?chan executor.FeishuCardBridgeResult {
	bridge.state.card_bridge_mu.@lock()
	defer {
		bridge.state.card_bridge_mu.unlock()
	}
	if request_id !in bridge.state.card_bridge_pending {
		return none
	}
	pending := bridge.state.card_bridge_pending[request_id] or { return none }
	ch := pending.ch
	bridge.state.card_bridge_pending.delete(request_id)
	return ch
}

fn (mut bridge FeishuCardBridgeContext) register_proxy_pending(ch chan feishu.BridgeProxyResult) !string {
	bridge.state.card_bridge_mu.@lock()
	defer { bridge.state.card_bridge_mu.unlock() }
	sender := bridge.state.card_bridge_client_conn or { return error('bridge_connection_unavailable') }
	if bridge.state.card_bridge_request_seq == u64(0xffffffffffffffff) {
		return error('bridge_request_id_exhausted')
	}
	bridge.state.card_bridge_request_seq++
	request_id := 'bridge-proxy-${bridge.state.card_bridge_request_seq}'
	bridge.state.card_bridge_proxy_pending[request_id] = feishu.CardBridgeProxyPending{ sender: sender, ch: ch }
	return request_id
}

fn (mut bridge FeishuCardBridgeContext) take_proxy_pending(request_id string) ?chan feishu.BridgeProxyResult {
	bridge.state.card_bridge_mu.@lock()
	defer {
		bridge.state.card_bridge_mu.unlock()
	}
	if request_id !in bridge.state.card_bridge_proxy_pending {
		return none
	}
	pending := bridge.state.card_bridge_proxy_pending[request_id] or { return none }
	ch := pending.ch
	bridge.state.card_bridge_proxy_pending.delete(request_id)
	return ch
}

fn (mut providers ProviderRuntimeHub) feishu_card_bridge_dispatch_callback(app_name string, trace_id string, summary executor.FeishuRuntimeEventSummary, payload string) !executor.FeishuCardBridgeResult {
	client_id := providers.feishu.card_bridge_target_id.trim_space()
	if client_id == '' {
		return error('bridge_target_unconfigured')
	}
	mut bridge := providers.feishu_card_bridge_context()
	if !bridge.has_client(client_id) {
		return error('bridge_client_unavailable:${client_id}')
	}
	ch := chan executor.FeishuCardBridgeResult{cap: 1}
	request_id := bridge.register_pending(ch, client_id)!
	defer {
		dummy := bridge.take_pending(request_id) or { ch }
		_ = dummy
	}
	frame := feishu.BridgeDispatchRequest{
		type_:       feishu.card_bridge_request_type
		request_id:  request_id
		trace_id:    trace_id
		app:         app_name
		event_type:  summary.event_type
		message_id:  summary.message_id
		target:      summary.target
		target_type: summary.target_type
		payload:     payload
		metadata:    {
			'event_kind':      summary.event_kind
			'event_id':        summary.event_id
			'open_message_id': summary.open_message_id
			'action_tag':      summary.action_tag
		}
	}
	delivery := feishu_card_bridge_dispatch_delivery_outcome(client_id, frame)
	relay_client_id := delivery.metadata['relay_client_id'] or { client_id }
	log.info('[bridge] 🔁 dispatch -> local target=${delivery.target} client=${relay_client_id} request_id=${request_id} trace_id=${trace_id} event_kind=${summary.event_kind} event_type=${summary.event_type} message_id=${summary.message_id} target=${summary.target}')
	if !bridge.send_pending(request_id, client_id, json.encode(frame,
		escape_unicode: true
		time_as_unix:   true
	)) {
		return error('bridge_send_failed:${relay_client_id}')
	}
	select {
		result := <-ch {
			if result.error != '' {
				log.error('[bridge] ❌ dispatch <- local error request_id=${request_id} trace_id=${trace_id}: ${result.error}')
				return error(result.error)
			}
			log.info('[bridge] ✅ dispatch <- local request_id=${request_id} trace_id=${trace_id} status=${result.status} body_len=${result.body.len}')
			return result
		}
		5 * time.second {
			log.error('[bridge] ❌ dispatch timeout request_id=${request_id} trace_id=${trace_id}')
			return error('bridge_timeout')
		}
	}
	return error('bridge_unreachable')
}

fn (mut providers ProviderRuntimeHub) feishu_card_bridge_proxy_request(action string, req upstream.UpstreamSendRequest) !feishu.BridgeProxyResult {
	if !providers.feishu_card_bridge_enabled() {
		return error('bridge_disabled')
	}
	ch := chan feishu.BridgeProxyResult{cap: 1}
	mut bridge := providers.feishu_card_bridge_context()
	request_id := bridge.register_proxy_pending(ch)!
	defer {
		dummy := bridge.take_proxy_pending(request_id) or { ch }
		_ = dummy
	}
	frame := feishu.BridgeProxyRequest{
		type_:      feishu.bridge_proxy_request_type
		request_id: request_id
		action:     action
		request:    req
	}
	trace_id := req.metadata['trace_id'] or { '' }
	delivery := feishu_card_bridge_proxy_delivery_outcome(frame, trace_id)
	log.info('[bridge] 🔁 proxy -> remote target=${delivery.target} request_id=${request_id} trace_id=${delivery.metadata['trace_id'] or {
		''
	}} action=${delivery.metadata['action'] or { action }} instance=${req.instance} target=${req.target} target_type=${req.target_type} stream_id=${delivery.metadata['stream_id'] or {
		''
	}} message_type=${req.message_type}')
	if !bridge.send_proxy_pending(request_id, json.encode(frame,
		escape_unicode: true
		time_as_unix:   true
	)) {
		return error('bridge_send_failed:server')
	}
	select {
		result := <-ch {
			if result.error != '' {
				log.error('[bridge] ❌ proxy <- remote error request_id=${request_id} trace_id=${req.metadata['trace_id'] or {
					''
				}} action=${action}: ${result.error}')
				return error(result.error)
			}
			log.info('[bridge] ✅ proxy <- remote request_id=${request_id} trace_id=${req.metadata['trace_id'] or {
				''
			}} action=${action} message_id=${result.message_id}')
			return result
		}
		5 * time.second {
			log.error('[bridge] ❌ proxy timeout request_id=${request_id} trace_id=${req.metadata['trace_id'] or {
				''
			}} action=${action}')
			return error('bridge_proxy_timeout')
		}
	}
	return error('bridge_proxy_unreachable')
}

fn (mut providers ProviderRuntimeHub) feishu_card_bridge_proxy_send(req upstream.UpstreamSendRequest) !upstream.UpstreamSendResult {
	result := providers.feishu_card_bridge_proxy_request('send', req)!
	return upstream.UpstreamSendResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}

fn (mut providers ProviderRuntimeHub) feishu_card_bridge_proxy_append(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	result := providers.feishu_card_bridge_proxy_request('append', req)!
	return upstream.UpstreamUpdateResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}

fn (mut providers ProviderRuntimeHub) feishu_card_bridge_proxy_finish(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	result := providers.feishu_card_bridge_proxy_request('finish', req)!
	return upstream.UpstreamUpdateResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}

fn (mut providers ProviderRuntimeHub) feishu_card_bridge_proxy_fail(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	result := providers.feishu_card_bridge_proxy_request('fail', req)!
	return upstream.UpstreamUpdateResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}

fn (mut providers ProviderRuntimeHub) feishu_card_bridge_proxy_update(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	result := providers.feishu_card_bridge_proxy_request('update', req)!
	return upstream.UpstreamUpdateResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}
