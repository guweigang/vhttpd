module main

import json
import log
import net
import net.http
import net.urllib
import net.websocket
import os
import time
import veb

const feishu_card_bridge_request_type = 'feishu_card_callback'
const feishu_card_bridge_result_type = 'feishu_card_callback_result'
const feishu_bridge_proxy_request_type = 'feishu_proxy_request'
const feishu_bridge_proxy_result_type = 'feishu_proxy_result'
const feishu_bridge_ping_type = 'feishu_bridge_ping'
const feishu_bridge_pong_type = 'feishu_bridge_pong'

struct FeishuCardBridgeEnvelope {
	type_      string @[json: 'type']
	request_id string @[json: 'request_id']
}

struct FeishuBridgeHeartbeatFrame {
	type_      string @[json: 'type']
	request_id string @[json: 'request_id']
	trace_id   string @[json: 'trace_id']
	sent_at    i64    @[json: 'sent_at']
}

struct FeishuCardBridgeDispatchRequest {
	type_      string            @[json: 'type']
	request_id string            @[json: 'request_id']
	trace_id   string            @[json: 'trace_id']
	app        string
	event_type string            @[json: 'event_type']
	message_id string            @[json: 'message_id']
	target     string
	target_type string           @[json: 'target_type']
	payload    string
	metadata   map[string]string
}

struct FeishuCardBridgeGatewayDispatchRequest {
	app         string
	trace_id    string            @[json: 'trace_id']
	event_type  string            @[json: 'event_type']
	message_id  string            @[json: 'message_id']
	target      string
	target_type string            @[json: 'target_type']
	payload     string
	metadata    map[string]string
}

struct FeishuCardBridgeDispatchResult {
	type_      string            @[json: 'type']
	request_id string            @[json: 'request_id']
	status     int
	headers    map[string]string
	body       string
	error      string
}

struct FeishuCardBridgeResult {
	status  int
	headers map[string]string
	body    string
	error   string
}

struct FeishuBridgeProxyRequest {
	type_      string @[json: 'type']
	request_id string @[json: 'request_id']
	action     string
	request    WebSocketUpstreamSendRequest
}

struct FeishuBridgeProxyResult {
mut:
	type_      string @[json: 'type']
	request_id string @[json: 'request_id']
	ok         bool
	provider   string
	instance   string
	message_id string @[json: 'message_id']
	error      string
}

@[heap]
struct FeishuCardBridgeServerState {
mut:
	app       &App = unsafe { nil }
	client_id string
}

fn feishu_card_bridge_default_client_id() string {
	host := (os.hostname() or { '' }).trim_space()
	if host != '' {
		return host
	}
	return 'local-main'
}

fn (mut app App) feishu_card_bridge_apply_env_fallbacks() {
	if app.feishu_card_bridge_ws_url.trim_space() == '' {
		app.feishu_card_bridge_ws_url = os.getenv('VHTTPD_FEISHU_CARD_BRIDGE_WS_URL').trim_space()
	}
	if app.feishu_card_bridge_client_id.trim_space() == '' {
		app.feishu_card_bridge_client_id = os.getenv('VHTTPD_FEISHU_CARD_BRIDGE_CLIENT_ID').trim_space()
	}
	if app.feishu_card_bridge_client_id.trim_space() == '' {
		app.feishu_card_bridge_client_id = feishu_card_bridge_default_client_id()
	}
	if app.feishu_card_bridge_token.trim_space() == '' {
		app.feishu_card_bridge_token = os.getenv('VHTTPD_FEISHU_CARD_BRIDGE_TOKEN').trim_space()
	}
	if app.feishu_card_bridge_target_id.trim_space() == '' {
		app.feishu_card_bridge_target_id = os.getenv('VHTTPD_FEISHU_CARD_BRIDGE_TARGET_ID').trim_space()
	}
	if app.feishu_card_bridge_target_id == '' {
		app.feishu_card_bridge_target_id = app.feishu_card_bridge_client_id
	}
}

fn (app &App) feishu_card_bridge_enabled() bool {
	return app.feishu_card_bridge_enabled_flag && app.feishu_card_bridge_ws_url.trim_space() != ''
}

fn (mut app App) feishu_card_bridge_set_client_conn(client &websocket.Client) {
	app.feishu_card_bridge_mu.@lock()
	app.feishu_card_bridge_client_conn = unsafe { client }
	app.feishu_card_bridge_mu.unlock()
}

fn (mut app App) feishu_card_bridge_clear_client_conn() {
	app.feishu_card_bridge_mu.@lock()
	app.feishu_card_bridge_client_conn = unsafe { nil }
	app.feishu_card_bridge_mu.unlock()
}

fn (mut app App) feishu_card_bridge_send_to_server(payload string) bool {
	if payload == '' {
		return false
	}
	mut client := &websocket.Client(unsafe { nil })
	app.feishu_card_bridge_mu.@lock()
	if !isnil(app.feishu_card_bridge_client_conn) {
		client = unsafe { app.feishu_card_bridge_client_conn }
	}
	app.feishu_card_bridge_mu.unlock()
	if isnil(client) {
		return false
	}
	app.feishu_card_bridge_send_mu.@lock()
	defer {
		app.feishu_card_bridge_send_mu.unlock()
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
	app.feishu_card_bridge_mu.@lock()
	app.feishu_card_bridge_clients[client_id] = unsafe { client }
	app.feishu_card_bridge_mu.unlock()
	log.info('[bridge] ✅ feishu card bridge client connected: ${client_id}')
}

fn (mut app App) feishu_card_bridge_unregister_client(client_id string) {
	if client_id == '' {
		return
	}
	app.feishu_card_bridge_mu.@lock()
	app.feishu_card_bridge_clients.delete(client_id)
	app.feishu_card_bridge_mu.unlock()
	log.info('[bridge] ℹ️ feishu card bridge client disconnected: ${client_id}')
}

fn (mut app App) feishu_card_bridge_has_client(client_id string) bool {
	if client_id == '' {
		return false
	}
	app.feishu_card_bridge_mu.@lock()
	defer {
		app.feishu_card_bridge_mu.unlock()
	}
	return client_id in app.feishu_card_bridge_clients
}

fn (mut app App) feishu_card_bridge_send(client_id string, payload string) bool {
	if client_id == '' || payload == '' {
		return false
	}
	mut client := &websocket.Client(unsafe { nil })
	app.feishu_card_bridge_mu.@lock()
	if conn := app.feishu_card_bridge_clients[client_id] {
		client = unsafe { conn }
	}
	app.feishu_card_bridge_mu.unlock()
	if isnil(client) {
		return false
	}
	app.feishu_card_bridge_send_mu.@lock()
	defer {
		app.feishu_card_bridge_send_mu.unlock()
	}
	mut c := unsafe { client }
	c.write_string(payload) or {
		log.error('[bridge] ❌ send failed client=${client_id}: ${err}')
		app.feishu_card_bridge_unregister_client(client_id)
		return false
	}
	return true
}

fn (mut app App) feishu_card_bridge_store_pending(request_id string, ch chan FeishuCardBridgeResult) {
	app.feishu_card_bridge_mu.@lock()
	app.feishu_card_bridge_pending[request_id] = ch
	app.feishu_card_bridge_mu.unlock()
}

fn (mut app App) feishu_card_bridge_take_pending(request_id string) ?chan FeishuCardBridgeResult {
	app.feishu_card_bridge_mu.@lock()
	defer {
		app.feishu_card_bridge_mu.unlock()
	}
	if request_id !in app.feishu_card_bridge_pending {
		return none
	}
	ch := app.feishu_card_bridge_pending[request_id]
	app.feishu_card_bridge_pending.delete(request_id)
	return ch
}

fn (mut app App) feishu_card_bridge_store_proxy_pending(request_id string, ch chan FeishuBridgeProxyResult) {
	app.feishu_card_bridge_mu.@lock()
	app.feishu_card_bridge_proxy_pending[request_id] = ch
	app.feishu_card_bridge_mu.unlock()
}

fn (mut app App) feishu_card_bridge_take_proxy_pending(request_id string) ?chan FeishuBridgeProxyResult {
	app.feishu_card_bridge_mu.@lock()
	defer {
		app.feishu_card_bridge_mu.unlock()
	}
	if request_id !in app.feishu_card_bridge_proxy_pending {
		return none
	}
	ch := app.feishu_card_bridge_proxy_pending[request_id]
	app.feishu_card_bridge_proxy_pending.delete(request_id)
	return ch
}

fn (mut app App) feishu_card_bridge_resolve_pending(result FeishuCardBridgeDispatchResult) {
	ch := app.feishu_card_bridge_take_pending(result.request_id) or { return }
	ch <- FeishuCardBridgeResult{
		status:  if result.status > 0 { result.status } else { 200 }
		headers: result.headers.clone()
		body:    result.body
		error:   result.error
	}
}

fn (mut app App) feishu_card_bridge_dispatch_callback(app_name string, trace_id string, summary FeishuRuntimeEventSummary, payload string) !FeishuCardBridgeResult {
	client_id := app.feishu_card_bridge_target_id.trim_space()
	if client_id == '' {
		return error('bridge_target_unconfigured')
	}
	if !app.feishu_card_bridge_has_client(client_id) {
		return error('bridge_client_unavailable:${client_id}')
	}
	request_id := 'bridge-${time.now().unix_micro()}'
	ch := chan FeishuCardBridgeResult{cap: 1}
	app.feishu_card_bridge_store_pending(request_id, ch)
	defer {
		dummy := app.feishu_card_bridge_take_pending(request_id) or { ch }
		_ = dummy
	}
	frame := FeishuCardBridgeDispatchRequest{
		type_:       feishu_card_bridge_request_type
		request_id:  request_id
		trace_id:    trace_id
		app:         app_name
		event_type:  summary.event_type
		message_id:  summary.message_id
		target:      summary.target
		target_type: summary.target_type
		payload:     payload
		metadata: {
			'event_kind':      summary.event_kind
			'event_id':        summary.event_id
			'open_message_id': summary.open_message_id
			'action_tag':      summary.action_tag
		}
	}
	log.info('[bridge] 🔁 dispatch -> local client=${client_id} request_id=${request_id} trace_id=${trace_id} event_kind=${summary.event_kind} event_type=${summary.event_type} message_id=${summary.message_id} target=${summary.target}')
	if !app.feishu_card_bridge_send(client_id, json.encode(frame)) {
		return error('bridge_send_failed:${client_id}')
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

fn (mut app App) feishu_card_bridge_proxy_request(action string, req WebSocketUpstreamSendRequest) !FeishuBridgeProxyResult {
	if !app.feishu_card_bridge_enabled() {
		return error('bridge_disabled')
	}
	request_id := 'bridge-proxy-${time.now().unix_micro()}'
	ch := chan FeishuBridgeProxyResult{cap: 1}
	app.feishu_card_bridge_store_proxy_pending(request_id, ch)
	defer {
		dummy := app.feishu_card_bridge_take_proxy_pending(request_id) or { ch }
		_ = dummy
	}
	frame := FeishuBridgeProxyRequest{
		type_:      feishu_bridge_proxy_request_type
		request_id: request_id
		action:     action
		request:    req
	}
	log.info('[bridge] 🔁 proxy -> remote request_id=${request_id} trace_id=${req.metadata["trace_id"] or { "" }} action=${action} instance=${req.instance} target=${req.target} target_type=${req.target_type} stream_id=${req.metadata["stream_id"] or { "" }} message_type=${req.message_type}')
	if !app.feishu_card_bridge_send_to_server(json.encode(frame)) {
		return error('bridge_send_failed:server')
	}
	select {
		result := <-ch {
			if result.error != '' {
				log.error('[bridge] ❌ proxy <- remote error request_id=${request_id} trace_id=${req.metadata["trace_id"] or { "" }} action=${action}: ${result.error}')
				return error(result.error)
			}
			log.info('[bridge] ✅ proxy <- remote request_id=${request_id} trace_id=${req.metadata["trace_id"] or { "" }} action=${action} message_id=${result.message_id}')
			return result
		}
		5 * time.second {
			log.error('[bridge] ❌ proxy timeout request_id=${request_id} trace_id=${req.metadata["trace_id"] or { "" }} action=${action}')
			return error('bridge_proxy_timeout')
		}
	}
	return error('bridge_proxy_unreachable')
}

fn (mut app App) feishu_card_bridge_proxy_send(req WebSocketUpstreamSendRequest) !WebSocketUpstreamSendResult {
	result := app.feishu_card_bridge_proxy_request('send', req)!
	return WebSocketUpstreamSendResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}

fn (mut app App) feishu_card_bridge_proxy_append(req WebSocketUpstreamSendRequest) !WebSocketUpstreamUpdateResult {
	result := app.feishu_card_bridge_proxy_request('append', req)!
	return WebSocketUpstreamUpdateResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}

fn (mut app App) feishu_card_bridge_proxy_finish(req WebSocketUpstreamSendRequest) !WebSocketUpstreamUpdateResult {
	result := app.feishu_card_bridge_proxy_request('finish', req)!
	return WebSocketUpstreamUpdateResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}

fn (mut app App) feishu_card_bridge_proxy_fail(req WebSocketUpstreamSendRequest) !WebSocketUpstreamUpdateResult {
	result := app.feishu_card_bridge_proxy_request('fail', req)!
	return WebSocketUpstreamUpdateResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}

fn (mut app App) feishu_card_bridge_proxy_update(req WebSocketUpstreamSendRequest) !WebSocketUpstreamUpdateResult {
	result := app.feishu_card_bridge_proxy_request('update', req)!
	return WebSocketUpstreamUpdateResult{
		ok:         result.ok
		provider:   if result.provider.trim_space() != '' { result.provider } else { 'feishu' }
		instance:   result.instance
		message_id: result.message_id
		error:      result.error
	}
}

fn feishu_card_bridge_client_message_cb(mut _ws websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut app := unsafe { &App(ref) }
	if msg.opcode != .text_frame {
		return
	}
	raw := msg.payload.bytestr()
	envelope := json.decode(FeishuCardBridgeEnvelope, raw) or {
		log.error('[bridge] ❌ invalid bridge envelope: ${err}')
		return
	}
	if envelope.type_ == feishu_bridge_pong_type {
		hb := json.decode(FeishuBridgeHeartbeatFrame, raw) or { FeishuBridgeHeartbeatFrame{} }
		log.info('[bridge] 💓 heartbeat pong received: request_id=${hb.request_id} trace_id=${hb.trace_id}')
		return
	}
	if envelope.type_ == feishu_bridge_proxy_result_type {
		result := json.decode(FeishuBridgeProxyResult, raw) or {
			log.error('[bridge] ❌ invalid proxy result frame: ${err}')
			return
		}
		ch := app.feishu_card_bridge_take_proxy_pending(result.request_id) or { return }
		ch <- result
		return
	}
	if envelope.type_ != feishu_card_bridge_request_type {
		return
	}
	req := json.decode(FeishuCardBridgeDispatchRequest, raw) or {
		log.error('[bridge] ❌ invalid request frame: ${err}')
		return
	}
	event_kind := if (req.metadata['event_kind'] or { '' }).trim_space() != '' {
		(req.metadata['event_kind'] or { '' }).trim_space()
	} else {
		'action'
	}
	log.info('[bridge] 📨 callback dispatch request: request_id=${req.request_id} trace_id=${req.trace_id} event_kind=${event_kind} event_type=${req.event_type} message_id=${req.message_id} target=${req.target}')
	outcome := app.kernel_dispatch_websocket_upstream_handled(app.kernel_websocket_upstream_dispatch_request_with_event(
		event_kind,
		req.request_id,
		websocket_upstream_provider_feishu,
		if req.app.trim_space() != '' { req.app } else { 'main' },
		if req.trace_id.trim_space() != '' { req.trace_id } else { req.request_id },
		req.event_type,
		req.message_id,
		req.target,
		req.target_type,
		req.payload,
		time.now().unix(),
		req.metadata.clone(),
	)) or {
		result := FeishuCardBridgeDispatchResult{
			type_:      feishu_card_bridge_result_type
			request_id: req.request_id
			status:     500
			headers:    {
				'content-type': 'application/json; charset=utf-8'
			}
			body:       json.encode(AdminErrorResponse{
				error: 'bridge_dispatch_error'
			})
			error:      err.msg()
		}
		mut ws2 := unsafe { _ws }
		ws2.write_string(json.encode(result)) or {}
		return
	}
	resp := outcome.response
	result := FeishuCardBridgeDispatchResult{
		type_:      feishu_card_bridge_result_type
		request_id: req.request_id
		status:     if resp.status > 0 { resp.status } else { 200 }
		headers:    resp.headers.clone()
		body:       resp.body
		error:      resp.error
	}
	log.info('[bridge] 📤 callback dispatch result: request_id=${req.request_id} trace_id=${req.trace_id} status=${result.status} error=${result.error}')
	mut ws3 := unsafe { _ws }
	ws3.write_string(json.encode(result)) or {
		log.error('[bridge] ❌ failed to send bridge result: ${err}')
	}
}

fn feishu_card_bridge_client_error_cb(mut _ws websocket.Client, err string, ref voidptr) ! {
	_ = _ws
	mut app := unsafe { &App(ref) }
	app.feishu_card_bridge_clear_client_conn()
	log.error('[bridge] ❌ bridge client websocket error: ${err}')
}

fn feishu_card_bridge_client_close_cb(mut _ws websocket.Client, code int, reason string, ref voidptr) ! {
	_ = _ws
	mut app := unsafe { &App(ref) }
	app.feishu_card_bridge_clear_client_conn()
	log.info('[bridge] ℹ️ bridge client websocket closed: code=${code} reason=${reason}')
}

fn feishu_card_bridge_client_heartbeat_loop(mut app App) {
	for {
		time.sleep(15 * time.second)
		if !app.feishu_card_bridge_enabled() {
			continue
		}
		request_id := 'bridge-hb-${time.now().unix_micro()}'
		frame := FeishuBridgeHeartbeatFrame{
			type_:      feishu_bridge_ping_type
			request_id: request_id
			trace_id:   'bridge-heartbeat'
			sent_at:    time.now().unix_milli()
		}
		if app.feishu_card_bridge_send_to_server(json.encode(frame)) {
			log.info('[bridge] 💓 heartbeat ping sent: request_id=${request_id}')
		}
	}
}

fn run_feishu_card_bridge_client(mut app App) {
	spawn feishu_card_bridge_client_heartbeat_loop(mut app)
	for {
		ws_url := app.feishu_card_bridge_ws_url.trim_space()
		if ws_url == '' {
			return
		}
		mut endpoint := ws_url
		parsed := urllib.parse(endpoint) or { urllib.URL{} }
		existing_query := if parsed.raw_query != '' { parsed.raw_query } else { '' }
		if !existing_query.contains('client_id=') && app.feishu_card_bridge_client_id.trim_space() != '' {
			endpoint += if endpoint.contains('?') {
				'&client_id=${urllib.query_escape(app.feishu_card_bridge_client_id)}'
			} else {
				'?client_id=${urllib.query_escape(app.feishu_card_bridge_client_id)}'
			}
		}
		if !existing_query.contains('token=') && app.feishu_card_bridge_token.trim_space() != '' {
			endpoint += if endpoint.contains('?') {
				'&token=${urllib.query_escape(app.feishu_card_bridge_token)}'
			} else {
				'?token=${urllib.query_escape(app.feishu_card_bridge_token)}'
			}
		}
		log.info('[bridge] 🔌 connecting feishu card bridge client -> ${endpoint}')
		mut client := websocket.new_client(endpoint,
			read_timeout:  time.infinite
			write_timeout: time.infinite
		) or {
			log.error('[bridge] ❌ bridge client create failed: ${err}')
			time.sleep(3 * time.second)
			continue
		}
		client.on_message_ref(feishu_card_bridge_client_message_cb, unsafe { &app })
		client.on_error_ref(feishu_card_bridge_client_error_cb, unsafe { &app })
		client.on_close_ref(feishu_card_bridge_client_close_cb, unsafe { &app })
		client.connect() or {
			log.error('[bridge] ❌ bridge client connect failed: ${err}')
			time.sleep(3 * time.second)
			continue
		}
		app.feishu_card_bridge_set_client_conn(client)
		client.listen() or {
			log.error('[bridge] ❌ bridge client listen failed: ${err}')
		}
		app.feishu_card_bridge_clear_client_conn()
		time.sleep(3 * time.second)
	}
}

fn feishu_card_bridge_server_message_cb(mut _ws websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &FeishuCardBridgeServerState(ref) }
	if msg.opcode != .text_frame {
		return
	}
	raw := msg.payload.bytestr()
	envelope := json.decode(FeishuCardBridgeEnvelope, raw) or {
		log.error('[bridge] ❌ invalid bridge envelope: ${err}')
		return
	}
	if envelope.type_ == feishu_bridge_ping_type {
		hb := json.decode(FeishuBridgeHeartbeatFrame, raw) or { FeishuBridgeHeartbeatFrame{} }
		log.info('[bridge] 💓 heartbeat ping received: request_id=${hb.request_id} trace_id=${hb.trace_id}')
		mut ws_hb := unsafe { _ws }
		ws_hb.write_string(json.encode(FeishuBridgeHeartbeatFrame{
			type_:      feishu_bridge_pong_type
			request_id: hb.request_id
			trace_id:   hb.trace_id
			sent_at:    time.now().unix_milli()
		})) or {}
		return
	}
	if envelope.type_ == feishu_card_bridge_result_type {
		result := json.decode(FeishuCardBridgeDispatchResult, raw) or {
			log.error('[bridge] ❌ invalid result frame: ${err}')
			return
		}
		state.app.feishu_card_bridge_resolve_pending(result)
		return
	}
	if envelope.type_ != feishu_bridge_proxy_request_type {
		return
	}
	req := json.decode(FeishuBridgeProxyRequest, raw) or {
		log.error('[bridge] ❌ invalid proxy request frame: ${err}')
		return
	}
	log.info('[bridge] 📨 proxy request: request_id=${req.request_id} trace_id=${req.request.metadata["trace_id"] or { "" }} action=${req.action} instance=${req.request.instance} target=${req.request.target} target_type=${req.request.target_type} stream_id=${req.request.metadata["stream_id"] or { "" }} message_type=${req.request.message_type}')
	mut result := FeishuBridgeProxyResult{
		type_:      feishu_bridge_proxy_result_type
		request_id: req.request_id
	}
	match req.action {
		'send' {
			send_result := state.app.websocket_upstream_send(req.request) or {
				result.error = err.msg()
				mut ws_err := unsafe { _ws }
				ws_err.write_string(json.encode(result)) or {}
				return
			}
			result.ok = send_result.ok
			result.provider = send_result.provider
			result.instance = send_result.instance
			result.message_id = send_result.message_id
			result.error = send_result.error
			stream_id := (req.request.metadata['stream_id'] or { '' }).trim_space()
			if result.ok && result.message_id.trim_space() != '' && stream_id != '' {
				state.app.feishu_runtime_register_stream_buffer(
					result.message_id,
					stream_id,
					if req.request.instance.trim_space() != '' { req.request.instance } else { result.instance },
					req.request.target,
					req.request.target_type,
					req.request.text,
				)
			}
		}
		'update' {
			update_result := state.app.websocket_upstream_update(req.request) or {
				result.error = err.msg()
				mut ws_err := unsafe { _ws }
				ws_err.write_string(json.encode(result)) or {}
				return
			}
			result.ok = update_result.ok
			result.provider = update_result.provider
			result.instance = update_result.instance
			result.message_id = update_result.message_id
			result.error = update_result.error
		}
		'append' {
			state.app.feishu_runtime_buffer_patch(req.request)
			result.ok = true
			result.provider = 'feishu'
			result.instance = req.request.instance
			result.message_id = req.request.target
		}
		'finish' {
			state.app.feishu_runtime_flush_buffer(req.request.target, req.request.content, true) or {
				result.error = err.msg()
				mut ws_err := unsafe { _ws }
				ws_err.write_string(json.encode(result)) or {}
				return
			}
			result.ok = true
			result.provider = 'feishu'
			result.instance = req.request.instance
			result.message_id = req.request.target
		}
		'fail' {
			state.app.feishu_runtime_clear_buffer(req.request.target)
			update_result := state.app.websocket_upstream_update(req.request) or {
				result.error = err.msg()
				mut ws_err := unsafe { _ws }
				ws_err.write_string(json.encode(result)) or {}
				return
			}
			result.ok = update_result.ok
			result.provider = update_result.provider
			result.instance = update_result.instance
			result.message_id = update_result.message_id
			result.error = update_result.error
		}
		else {
			result.error = 'unsupported_proxy_action:${req.action}'
		}
	}
	mut ws2 := unsafe { _ws }
	log.info('[bridge] 📤 proxy result: request_id=${req.request_id} trace_id=${req.request.metadata["trace_id"] or { "" }} action=${req.action} ok=${result.ok} message_id=${result.message_id} error=${result.error}')
	ws2.write_string(json.encode(result)) or {
		log.error('[bridge] ❌ failed to send proxy result: ${err}')
	}
}

fn feishu_card_bridge_server_close_cb(mut _ws websocket.Client, _code int, _reason string, ref voidptr) ! {
	mut state := unsafe { &FeishuCardBridgeServerState(ref) }
	state.app.feishu_card_bridge_unregister_client(state.client_id)
}

fn handle_feishu_card_bridge_server_session(mut app App, mut conn net.TcpConn, key string, client_id string, req_id string) {
	mut server := websocket.new_server(.ip, 0, '')
	mut state := &FeishuCardBridgeServerState{
		app:       unsafe { &app }
		client_id: client_id
	}
	server.on_connect(fn [mut app, state] (mut sc websocket.ServerClient) !bool {
		app.feishu_card_bridge_register_client(state.client_id, sc.client)
		return true
	}) or {}
	server.on_message_ref(feishu_card_bridge_server_message_cb, state)
	server.on_close_ref(feishu_card_bridge_server_close_cb, state)
	server.handle_handshake(mut conn, key) or {
		app.feishu_card_bridge_unregister_client(client_id)
		log.error('[bridge] ❌ bridge ws handshake failed req=${req_id}: ${err}')
	}
}

@['/bridge/ws'; get]
pub fn (mut app App) feishu_card_bridge_ws(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/bridge/ws' } else { ctx.req.url }
	request_path, _ := normalize_request_target(path)
	normalized_path := normalize_path(request_path)
	log.info('[bridge] route feishu_card_bridge_ws path=${path} request_path=${request_path} normalized=${normalized_path} upgrade=${if is_websocket_upgrade(ctx.req) { "true" } else { "false" }}')
	if normalized_path != '/bridge/ws' {
		ctx.res.set_status(http.status_from_int(404))
		return ctx.text('Not Found')
	}
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	key := websocket_upgrade_key(ctx.req)
	if ctx.req.method.str().to_upper() != 'GET' || key == '' || !is_websocket_upgrade(ctx.req) {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(426))
		ctx.set_custom_header('upgrade', 'websocket') or {}
		return ctx.text('Upgrade Required')
	}
	_, query_string := normalize_request_target(path)
	query := parse_query_map(query_string)
	client_id := (query['client_id'] or { '' }).trim_space()
	token := (query['token'] or { '' }).trim_space()
	expected := app.feishu_card_bridge_token.trim_space()
	if client_id == '' || (expected != '' && token != expected) {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text('Forbidden')
	}
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut conn := ctx.conn
	spawn handle_feishu_card_bridge_server_session(mut app, mut conn, key, client_id, req_id)
	return veb.no_result()
}

@['/gateway/bridge/dispatch'; post]
pub fn (mut app App) feishu_card_bridge_gateway_dispatch(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/gateway/bridge/dispatch' } else { ctx.req.url }
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.api_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	req := json.decode(FeishuCardBridgeGatewayDispatchRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'invalid_json'
		}))
	}
	summary := feishu_runtime_event_summary(req.payload)
	bridge_trace_id := if req.trace_id.trim_space() != '' { req.trace_id } else { trace_id }
	result := app.feishu_card_bridge_dispatch_callback(req.app, bridge_trace_id, FeishuRuntimeEventSummary{
		event_id:        summary.event_id
		event_kind:      if summary.event_kind != '' { summary.event_kind } else { 'action' }
		event_type:      if req.event_type.trim_space() != '' { req.event_type } else { summary.event_type }
		message_id:      if req.message_id.trim_space() != '' { req.message_id } else { summary.message_id }
		target:          if req.target.trim_space() != '' { req.target } else { summary.target }
		target_type:     if req.target_type.trim_space() != '' { req.target_type } else { summary.target_type }
		open_message_id: summary.open_message_id
		action_tag:      summary.action_tag
	}, req.payload) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'bridge_dispatch_failed'
		}))
	}
	for name, value in result.headers {
		if name.to_lower() == 'content-type' {
			continue
		}
		ctx.set_custom_header(name, value) or {}
	}
	ctx.res.set_status(http.status_from_int(if result.status > 0 { result.status } else { 200 }))
	ctx.set_content_type(result.headers['content-type'] or { 'application/json; charset=utf-8' })
	return ctx.text(result.body)
}
