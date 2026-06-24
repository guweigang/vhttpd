module main

import admin
import json
import log
import net.urllib
import net.websocket
import time
import feishu

// C callback trampoline; keep as a free function. Passing static methods to
// net.websocket callback registration can pass `v -check-syntax` and fail later
// during C compilation with undeclared `__static__*_cb` symbols.
fn feishu_card_bridge_client_message_cb(mut _ws websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut app := unsafe { &App(ref) }
	mut bridge := app.providers.feishu_card_bridge_context()
	if msg.opcode != .text_frame {
		return
	}
	raw := msg.payload.bytestr()
	envelope := json.decode(feishu.BridgeEnvelope, raw) or {
		log.error('[bridge] ❌ invalid bridge envelope: ${err}')
		return
	}
	if envelope.type_ == feishu.bridge_pong_type {
		hb := json.decode(feishu.BridgeHeartbeatFrame, raw) or { feishu.BridgeHeartbeatFrame{} }
		log.info('[bridge] 💓 heartbeat pong received: request_id=${hb.request_id} trace_id=${hb.trace_id}')
		return
	}
	if envelope.type_ == feishu.bridge_proxy_result_type {
		result := json.decode(feishu.BridgeProxyResult, raw) or {
			log.error('[bridge] ❌ invalid proxy result frame: ${err}')
			return
		}
		ch := bridge.take_proxy_pending(result.request_id) or { return }
		ch <- result
		return
	}
	if envelope.type_ != feishu.card_bridge_request_type {
		return
	}
	req := json.decode(feishu.BridgeDispatchRequest, raw) or {
		log.error('[bridge] ❌ invalid request frame: ${err}')
		return
	}
	event_kind := if (req.metadata['event_kind'] or { '' }).trim_space() != '' {
		(req.metadata['event_kind'] or { '' }).trim_space()
	} else {
		'action'
	}
	log.info('[bridge] 📨 callback dispatch request: request_id=${req.request_id} trace_id=${req.trace_id} event_kind=${event_kind} event_type=${req.event_type} message_id=${req.message_id} target=${req.target}')
	outcome := app.kernel_dispatch_websocket_upstream_handled(app.kernel_websocket_upstream_dispatch_request_with_event(event_kind,
		req.request_id, websocket_upstream_provider_feishu, if req.app.trim_space() != '' {
		req.app
	} else {
		'main'
	}, if req.trace_id.trim_space() != '' { req.trace_id } else { req.request_id }, req.event_type,
		req.message_id, req.target, req.target_type, req.payload, time.now().unix(),
		req.metadata.clone())) or {
		result := feishu.BridgeDispatchResult{
			type_:      feishu.card_bridge_result_type
			request_id: req.request_id
			status:     500
			headers:    {
				'content-type': 'application/json; charset=utf-8'
			}
			body:       json.encode(admin.AdminErrorResponse{
				error: 'bridge_dispatch_error'
			})
			error:      err.msg()
		}
		mut ws2 := unsafe { _ws }
		ws2.write_string(json.encode(result)) or {} // safe to ignore: write failure usually means peer disconnected
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
	mut ws3 := unsafe { _ws }
	ws3.write_string(json.encode(result)) or {
		log.error('[bridge] ❌ failed to send bridge result: ${err}')
	}
}

// C callback trampoline; keep as a free function, see note above.
fn feishu_card_bridge_client_error_cb(mut _ws websocket.Client, err string, ref voidptr) ! {
	_ = _ws
	mut app := unsafe { &App(ref) }
	mut bridge := app.providers.feishu_card_bridge_context()
	bridge.clear_client_conn()
	log.error('[bridge] ❌ bridge client websocket error: ${err}')
}

// C callback trampoline; keep as a free function, see note above.
fn feishu_card_bridge_client_close_cb(mut _ws websocket.Client, code int, reason string, ref voidptr) ! {
	_ = _ws
	mut app := unsafe { &App(ref) }
	mut bridge := app.providers.feishu_card_bridge_context()
	bridge.clear_client_conn()
	log.info('[bridge] ℹ️ bridge client websocket closed: code=${code} reason=${reason}')
}

fn FeishuCardBridgeRuntime.client_heartbeat_loop(mut app App) {
	for {
		time.sleep(15 * time.second)
		if !app.feishu_card_bridge_enabled() {
			continue
		}
		request_id := 'bridge-hb-${time.now().unix_micro()}'
		frame := feishu.BridgeHeartbeatFrame{
			type_:      feishu.bridge_ping_type
			request_id: request_id
			trace_id:   'bridge-heartbeat'
			sent_at:    time.now().unix_milli()
		}
		mut bridge := app.providers.feishu_card_bridge_context()
		if bridge.send_to_server(json.encode(frame)) {
			log.info('[bridge] 💓 heartbeat ping sent: request_id=${request_id}')
		}
	}
}

fn FeishuCardBridgeRuntime.run_client(mut app App) {
	spawn FeishuCardBridgeRuntime.client_heartbeat_loop(mut app)
	for {
		ws_url := app.providers.feishu.card_bridge_ws_url.trim_space()
		if ws_url == '' {
			return
		}
		mut endpoint := ws_url
		parsed := urllib.parse(endpoint) or { urllib.URL{} }
		existing_query := if parsed.raw_query != '' { parsed.raw_query } else { '' }
		if !existing_query.contains('client_id=')
			&& app.providers.feishu.card_bridge_client_id.trim_space() != '' {
			endpoint += if endpoint.contains('?') {
				'&client_id=${urllib.query_escape(app.providers.feishu.card_bridge_client_id)}'
			} else {
				'?client_id=${urllib.query_escape(app.providers.feishu.card_bridge_client_id)}'
			}
		}
		if !existing_query.contains('token=') && app.providers.feishu.card_bridge_token.trim_space() != '' {
			endpoint += if endpoint.contains('?') {
				'&token=${urllib.query_escape(app.providers.feishu.card_bridge_token)}'
			} else {
				'?token=${urllib.query_escape(app.providers.feishu.card_bridge_token)}'
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
		// Keep these as free-function trampolines; see callback note above.
		client.on_message_ref(feishu_card_bridge_client_message_cb, unsafe { &app })
		client.on_error_ref(feishu_card_bridge_client_error_cb, unsafe { &app })
		client.on_close_ref(feishu_card_bridge_client_close_cb, unsafe { &app })
		client.connect() or {
			log.error('[bridge] ❌ bridge client connect failed: ${err}')
			time.sleep(3 * time.second)
			continue
		}
		mut bridge := app.providers.feishu_card_bridge_context()
		bridge.set_client_conn(client)
		client.listen() or { log.error('[bridge] ❌ bridge client listen failed: ${err}') }
		bridge.clear_client_conn()
		time.sleep(3 * time.second)
	}
}
