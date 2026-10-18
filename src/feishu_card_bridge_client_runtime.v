module main

import admin
import json2 as json
import log
import net.urllib
import net.websocket
import time
import feishu
import ws
import connection_runtime

@[heap]
struct FeishuCardBridgeClientState {
mut:
	host   FeishuBridgeClientHost  @[required]
	bridge FeishuCardBridgeContext @[required]
	sender ?&connection_runtime.WebSocketSender
}

fn (mut state FeishuCardBridgeClientState) reply(payload string) ! {
	mut sender := state.sender or { return error('bridge_connection_unavailable') }
	sender.write_string(payload)!
}

// C callback trampoline; keep as a free function. Passing static methods to
// net.websocket callback registration can pass `v -check-syntax` and fail later
// during C compilation with undeclared `__static__*_cb` symbols.
fn feishu_card_bridge_client_message_cb(mut _ws websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &FeishuCardBridgeClientState(ref) }
	mut bridge := state.bridge
	if msg.opcode != .text_frame {
		return
	}
	raw := msg.payload.bytestr()
	envelope := json.decode[feishu.BridgeEnvelope](raw) or {
		log.error('[bridge] ❌ invalid bridge envelope: ${err}')
		return
	}
	if envelope.type_ == feishu.bridge_pong_type {
		hb := json.decode[feishu.BridgeHeartbeatFrame](raw) or { feishu.BridgeHeartbeatFrame{} }
		log.info('[bridge] 💓 heartbeat pong received: request_id=${hb.request_id} trace_id=${hb.trace_id}')
		return
	}
	if envelope.type_ == feishu.bridge_proxy_result_type {
		result := json.decode[feishu.BridgeProxyResult](raw) or {
			log.error('[bridge] ❌ invalid proxy result frame: ${err}')
			return
		}
		ch := bridge.take_proxy_pending_from(result.request_id, &_ws) or { return }
		ch <- result
		return
	}
	if envelope.type_ != feishu.card_bridge_request_type {
		return
	}
	req := json.decode[feishu.BridgeDispatchRequest](raw) or {
		log.error('[bridge] ❌ invalid request frame: ${err}')
		return
	}
	event_kind := if (req.metadata['event_kind'] or { '' }).trim_space() != '' {
		(req.metadata['event_kind'] or { '' }).trim_space()
	} else {
		'action'
	}
	log.info('[bridge] 📨 callback dispatch request: request_id=${req.request_id} trace_id=${req.trace_id} event_kind=${event_kind} event_type=${req.event_type} message_id=${req.message_id} target=${req.target}')
	outcome := state.host.bridge_dispatch_request(req, event_kind) or {
		result := feishu.BridgeDispatchResult{
			type_:      feishu.card_bridge_result_type
			request_id: req.request_id
			status:     500
			headers:    {
				'content-type': 'application/json; charset=utf-8'
			}
			body:       json.encode(admin.AdminErrorResponse{
				error: 'bridge_dispatch_error'
			}, escape_unicode: true, time_as_unix: true)
			error:      err.msg()
		}
		state.reply(json.encode(result,
			escape_unicode: true
			time_as_unix:   true
		)) or {} // safe to ignore: write failure usually means peer disconnected
		return
	}
	resp := outcome.response
	result := feishu.BridgeDispatchResult{
		type_:      feishu.card_bridge_result_type
		request_id: req.request_id
		status:     if resp.status > 0 { resp.status } else { 200 }
		headers:    resp.headers.clone()
		body:       resp.body
		error:      resp.error
	}
	log.info('[bridge] 📤 callback dispatch result: request_id=${req.request_id} trace_id=${req.trace_id} status=${result.status} error=${result.error}')
	state.reply(json.encode(result,
		escape_unicode: true
		time_as_unix:   true
	)) or {
		log.error('[bridge] ❌ failed to send bridge result: ${err}')
	}
}

// C callback trampoline; keep as a free function, see note above.
fn feishu_card_bridge_client_error_cb(mut _ws websocket.Client, err string, ref voidptr) ! {
	_ = _ws
	mut state := unsafe { &FeishuCardBridgeClientState(ref) }
	mut bridge := state.bridge
	bridge.clear_client_conn(&_ws)
	log.error('[bridge] ❌ bridge client websocket error: ${err}')
}

// C callback trampoline; keep as a free function, see note above.
fn feishu_card_bridge_client_close_cb(mut _ws websocket.Client, code int, reason string, ref voidptr) ! {
	_ = _ws
	mut state := unsafe { &FeishuCardBridgeClientState(ref) }
	mut bridge := state.bridge
	bridge.clear_client_conn(&_ws)
	log.info('[bridge] ℹ️ bridge client websocket closed: code=${code} reason=${reason}')
}

fn FeishuCardBridgeRuntime.client_heartbeat_loop(bridge_context FeishuCardBridgeContext, mut session connection_runtime.Session) {
	mut bridge := bridge_context
	for session.wait(15 * time.second) {
		if !(bridge.state.card_bridge_enabled_flag && bridge.state.card_bridge_ws_url.trim_space() != '') {
			session.request_stop()
			return
		}
		request_id := 'bridge-hb-${time.now().unix_micro()}'
		frame := feishu.BridgeHeartbeatFrame{
			type_:      feishu.bridge_ping_type
			request_id: request_id
			trace_id:   'bridge-heartbeat'
			sent_at:    time.now().unix_milli()
		}
		if bridge.send_to_server(json.encode(frame, escape_unicode: true, time_as_unix: true)) {
			log.info('[bridge] 💓 heartbeat ping sent: request_id=${request_id}')
		} else {
			session.note_reason('heartbeat_send_failed')
			session.request_stop()
			return
		}
	}
}

fn FeishuCardBridgeRuntime.start_client(mut host FeishuBridgeClientHost) bool {
	mut bridge := host.bridge_context()
	mut run := bridge.state.background_runs.reserve('client') or { return false }
	spawn FeishuCardBridgeRuntime.run_client(mut host, mut run)
	return true
}

fn FeishuCardBridgeRuntime.run_client(mut host FeishuBridgeClientHost, mut run connection_runtime.Run) {
	mut bridge := host.bridge_context()
	defer { bridge.state.background_runs.release('client', mut run) }
	mut callback_state := &FeishuCardBridgeClientState{ host: host, bridge: bridge }
	ctx := ws.UpstreamRuntimeContext{
		enabled_fn:         fn [bridge] (_ string, _ string) bool {
			return bridge.state.card_bridge_enabled_flag && bridge.state.card_bridge_ws_url.trim_space() != ''
		}
		reconnect_delay_fn: fn (_ string, _ string) int { return 3000 }
		connecting_fn:      fn (_ string, _ string) {}
		pull_url_fn:        fn [bridge] (_ string, _ string) !string { return bridge.endpoint() }
		prepare_fn:         fn (_ string, _ string, _ string) !ws.UpstreamPreparation {
			return ws.UpstreamPreparation{ activate_fn: fn (mut _ websocket.Client) ! {} }
		}
		connected_fn:       fn (_ string, _ string, _ string) {}
		disconnected_fn:    fn (_ string, _ string, reason string) {
			log.info('[bridge] client disconnected: ${reason}')
		}
		handle_message_fn:  fn [callback_state] (_ string, _ string, mut client websocket.Client, msg &websocket.Message) ! {
			feishu_card_bridge_client_message_cb(mut client, msg, callback_state)!
		}
		post_connect_fn:    fn [mut bridge, mut callback_state] (_ string, _ string, _ string, mut session connection_runtime.Session, mut client websocket.Client) []thread {
			mut workers := []thread{}
			if session.stopped() { return workers }
			callback_state.sender = bridge.set_client_conn(&client)
			workers << spawn FeishuCardBridgeRuntime.client_heartbeat_loop(bridge, mut session)
			return workers
		}
		release_client_fn:  fn [mut bridge, mut callback_state] (_ string, _ string, client &websocket.Client) {
			if mut owner := callback_state.sender {
				owner.retire()
				owner.wait_idle()
			}
			callback_state.sender = none
			bridge.clear_client_conn(client)
		}
	}
	ctx.run_provider('bridge', 'client', mut run)
}

fn (bridge FeishuCardBridgeContext) endpoint() !string {
	mut endpoint := bridge.state.card_bridge_ws_url.trim_space()
	if endpoint == '' { return error('bridge_endpoint_missing') }
	parsed := urllib.parse(endpoint)!
	existing_query := parsed.raw_query
	if !existing_query.contains('client_id=') && bridge.state.card_bridge_client_id.trim_space() != '' {
		endpoint += if endpoint.contains('?') {
			'&client_id=${urllib.query_escape(bridge.state.card_bridge_client_id)}'
		} else {
			'?client_id=${urllib.query_escape(bridge.state.card_bridge_client_id)}'
		}
	}
	if !existing_query.contains('token=') && bridge.state.card_bridge_token.trim_space() != '' {
		endpoint += if endpoint.contains('?') {
			'&token=${urllib.query_escape(bridge.state.card_bridge_token)}'
		} else {
			'?token=${urllib.query_escape(bridge.state.card_bridge_token)}'
		}
	}
	return endpoint
}
