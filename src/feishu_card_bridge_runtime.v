module main

import executor
import json
import log
import net.websocket
import os
import time
import upstream
import feishu

struct FeishuCardBridgeRuntime {}

fn FeishuCardBridgeRuntime.default_client_id() string {
	host := (os.hostname() or { '' }).trim_space()
	if host != '' {
		return host
	}
	return 'local-main'
}

fn (mut app App) feishu_card_bridge_apply_env_fallbacks() {
	if app.providers.feishu.card_bridge_ws_url.trim_space() == '' {
		app.providers.feishu.card_bridge_ws_url = os.getenv('VHTTPD_FEISHU_CARD_BRIDGE_WS_URL').trim_space()
	}
	if app.providers.feishu.card_bridge_client_id.trim_space() == '' {
		app.providers.feishu.card_bridge_client_id =
			os.getenv('VHTTPD_FEISHU_CARD_BRIDGE_CLIENT_ID').trim_space()
	}
	if app.providers.feishu.card_bridge_client_id.trim_space() == '' {
		app.providers.feishu.card_bridge_client_id = FeishuCardBridgeRuntime.default_client_id()
	}
	if app.providers.feishu.card_bridge_token.trim_space() == '' {
		app.providers.feishu.card_bridge_token = os.getenv('VHTTPD_FEISHU_CARD_BRIDGE_TOKEN').trim_space()
	}
	if app.providers.feishu.card_bridge_target_id.trim_space() == '' {
		app.providers.feishu.card_bridge_target_id =
			os.getenv('VHTTPD_FEISHU_CARD_BRIDGE_TARGET_ID').trim_space()
	}
	if app.providers.feishu.card_bridge_target_id == '' {
		app.providers.feishu.card_bridge_target_id = app.providers.feishu.card_bridge_client_id
	}
}

fn (app &App) feishu_card_bridge_enabled() bool {
	return app.providers.feishu.card_bridge_enabled_flag && app.providers.feishu.card_bridge_ws_url.trim_space() != ''
}

fn (mut app App) feishu_card_bridge_set_client_conn(client &websocket.Client) {
	app.providers.feishu.card_bridge_mu.@lock()
	app.providers.feishu.card_bridge_client_conn = unsafe { client }
	app.providers.feishu.card_bridge_mu.unlock()
}

fn (mut app App) feishu_card_bridge_clear_client_conn() {
	app.providers.feishu.card_bridge_mu.@lock()
	app.providers.feishu.card_bridge_client_conn = unsafe { nil }
	app.providers.feishu.card_bridge_mu.unlock()
}

fn (mut app App) feishu_card_bridge_send_to_server(payload string) bool {
	if payload == '' {
		return false
	}
	mut client := &websocket.Client(unsafe { nil })
	app.providers.feishu.card_bridge_mu.@lock()
	if !isnil(app.providers.feishu.card_bridge_client_conn) {
		client = unsafe { app.providers.feishu.card_bridge_client_conn }
	}
	app.providers.feishu.card_bridge_mu.unlock()
	if isnil(client) {
		return false
	}
	app.providers.feishu.card_bridge_send_mu.@lock()
	defer {
		app.providers.feishu.card_bridge_send_mu.unlock()
	}
	client.write_string(payload) or {
		log.error('[bridge] ❌ send to server failed: ${err}')
		app.feishu_card_bridge_clear_client_conn()
		return false
	}
	return true
}

fn (mut app App) feishu_card_bridge_register_client(client_id string, client &websocket.Client) {
	if client_id == '' || isnil(client) {
		return
	}
	app.providers.feishu.card_bridge_mu.@lock()
	app.providers.feishu.card_bridge_clients[client_id] = unsafe { client }
	app.providers.feishu.card_bridge_mu.unlock()
	log.info('[bridge] ✅ feishu card bridge client connected: ${client_id}')
}

fn (mut app App) feishu_card_bridge_unregister_client(client_id string) {
	if client_id == '' {
		return
	}
	app.providers.feishu.card_bridge_mu.@lock()
	app.providers.feishu.card_bridge_clients.delete(client_id)
	app.providers.feishu.card_bridge_mu.unlock()
	log.info('[bridge] ℹ️ feishu card bridge client disconnected: ${client_id}')
}

fn (mut app App) feishu_card_bridge_has_client(client_id string) bool {
	if client_id == '' {
		return false
	}
	app.providers.feishu.card_bridge_mu.@lock()
	defer {
		app.providers.feishu.card_bridge_mu.unlock()
	}
	return client_id in app.providers.feishu.card_bridge_clients
}

fn (mut app App) feishu_card_bridge_send(client_id string, payload string) bool {
	if client_id == '' || payload == '' {
		return false
	}
	mut client := &websocket.Client(unsafe { nil })
	app.providers.feishu.card_bridge_mu.@lock()
	if conn := app.providers.feishu.card_bridge_clients[client_id] {
		client = unsafe { conn }
	}
	app.providers.feishu.card_bridge_mu.unlock()
	if isnil(client) {
		return false
	}
	app.providers.feishu.card_bridge_send_mu.@lock()
	defer {
		app.providers.feishu.card_bridge_send_mu.unlock()
	}
	mut c := unsafe { client }
	c.write_string(payload) or {
		log.error('[bridge] ❌ send failed client=${client_id}: ${err}')
		app.feishu_card_bridge_unregister_client(client_id)
		return false
	}
	return true
}

fn (mut app App) feishu_card_bridge_store_pending(request_id string, ch chan executor.FeishuCardBridgeResult) {
	app.providers.feishu.card_bridge_mu.@lock()
	app.providers.feishu.card_bridge_pending[request_id] = ch
	app.providers.feishu.card_bridge_mu.unlock()
}

fn (mut app App) feishu_card_bridge_take_pending(request_id string) ?chan executor.FeishuCardBridgeResult {
	app.providers.feishu.card_bridge_mu.@lock()
	defer {
		app.providers.feishu.card_bridge_mu.unlock()
	}
	if request_id !in app.providers.feishu.card_bridge_pending {
		return none
	}
	ch := app.providers.feishu.card_bridge_pending[request_id]
	app.providers.feishu.card_bridge_pending.delete(request_id)
	return ch
}

fn (mut app App) feishu_card_bridge_store_proxy_pending(request_id string, ch chan feishu.BridgeProxyResult) {
	app.providers.feishu.card_bridge_mu.@lock()
	app.providers.feishu.card_bridge_proxy_pending[request_id] = ch
	app.providers.feishu.card_bridge_mu.unlock()
}

fn (mut app App) feishu_card_bridge_take_proxy_pending(request_id string) ?chan feishu.BridgeProxyResult {
	app.providers.feishu.card_bridge_mu.@lock()
	defer {
		app.providers.feishu.card_bridge_mu.unlock()
	}
	if request_id !in app.providers.feishu.card_bridge_proxy_pending {
		return none
	}
	ch := app.providers.feishu.card_bridge_proxy_pending[request_id]
	app.providers.feishu.card_bridge_proxy_pending.delete(request_id)
	return ch
}

fn (mut app App) feishu_card_bridge_resolve_pending(result feishu.BridgeDispatchResult) {
	ch := app.feishu_card_bridge_take_pending(result.request_id) or { return }
	ch <- executor.FeishuCardBridgeResult{
		status:  if result.status > 0 { result.status } else { 200 }
		headers: result.headers.clone()
		body:    result.body
		error:   result.error
	}
}

fn (mut app App) feishu_card_bridge_dispatch_callback(app_name string, trace_id string, summary executor.FeishuRuntimeEventSummary, payload string) !executor.FeishuCardBridgeResult {
	client_id := app.providers.feishu.card_bridge_target_id.trim_space()
	if client_id == '' {
		return error('bridge_target_unconfigured')
	}
	if !app.feishu_card_bridge_has_client(client_id) {
		return error('bridge_client_unavailable:${client_id}')
	}
	request_id := 'bridge-${time.now().unix_micro()}'
	ch := chan executor.FeishuCardBridgeResult{cap: 1}
	app.feishu_card_bridge_store_pending(request_id, ch)
	defer {
		dummy := app.feishu_card_bridge_take_pending(request_id) or { ch }
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
	if !app.feishu_card_bridge_send(relay_client_id, json.encode(frame)) {
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

fn (mut app App) feishu_card_bridge_proxy_request(action string, req upstream.UpstreamSendRequest) !feishu.BridgeProxyResult {
	if !app.feishu_card_bridge_enabled() {
		return error('bridge_disabled')
	}
	request_id := 'bridge-proxy-${time.now().unix_micro()}'
	ch := chan feishu.BridgeProxyResult{cap: 1}
	app.feishu_card_bridge_store_proxy_pending(request_id, ch)
	defer {
		dummy := app.feishu_card_bridge_take_proxy_pending(request_id) or { ch }
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
	if !app.feishu_card_bridge_send_to_server(json.encode(frame)) {
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

fn (mut app App) feishu_card_bridge_proxy_send(req upstream.UpstreamSendRequest) !upstream.UpstreamSendResult {
	result := app.feishu_card_bridge_proxy_request('send', req)!
	return upstream.UpstreamSendResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}

fn (mut app App) feishu_card_bridge_proxy_append(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	result := app.feishu_card_bridge_proxy_request('append', req)!
	return upstream.UpstreamUpdateResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}

fn (mut app App) feishu_card_bridge_proxy_finish(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	result := app.feishu_card_bridge_proxy_request('finish', req)!
	return upstream.UpstreamUpdateResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}

fn (mut app App) feishu_card_bridge_proxy_fail(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	result := app.feishu_card_bridge_proxy_request('fail', req)!
	return upstream.UpstreamUpdateResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}

fn (mut app App) feishu_card_bridge_proxy_update(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	result := app.feishu_card_bridge_proxy_request('update', req)!
	return upstream.UpstreamUpdateResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}
