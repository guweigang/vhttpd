module main

import json
import log
import net
import net.websocket
import time
import executor
import dispatch
import upstream.transport
import feishu
import veb

@[heap]
struct FeishuCardBridgeServerState {
mut:
	app       &App = unsafe { nil }
	client_id string
}

fn feishu_card_bridge_http_response(mut app App, mut ctx Context, method string, path string, req_id string, trace_id string, start_ms i64, status int, headers map[string]string, body string, error_class string) veb.Result {
	mut event_metadata := {
		'provider': 'feishu'
		'bridge':   'card'
	}
	mut outcome_headers := headers.clone()
	if error_class != '' {
		event_metadata['error_class'] = error_class
		outcome_headers['x-vhttpd-error-class'] = error_class
	}
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request(method,
		path, path, '', if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } }, req_id,
		trace_id, start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(status,
		outcome_headers, body), event_metadata), none)
}

// C callback trampoline; keep as a free function. Passing static methods to
// net.websocket callback registration can pass `v -check-syntax` and fail later
// during C compilation with undeclared `__static__*_cb` symbols.
fn feishu_card_bridge_server_message_cb(mut _ws websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &FeishuCardBridgeServerState(ref) }
	mut bridge := state.app.providers.feishu_card_bridge_context()
	if msg.opcode != .text_frame {
		return
	}
	raw := msg.payload.bytestr()
	envelope := json.decode(feishu.BridgeEnvelope, raw) or {
		log.error('[bridge] ❌ invalid bridge envelope: ${err}')
		return
	}
	if envelope.type_ == feishu.bridge_ping_type {
		hb := json.decode(feishu.BridgeHeartbeatFrame, raw) or { feishu.BridgeHeartbeatFrame{} }
		log.info('[bridge] 💓 heartbeat ping received: request_id=${hb.request_id} trace_id=${hb.trace_id}')
		mut ws_hb := unsafe { _ws }
		ws_hb.write_string(json.encode(feishu.BridgeHeartbeatFrame{
			type_:      feishu.bridge_pong_type
			request_id: hb.request_id
			trace_id:   hb.trace_id
			sent_at:    time.now().unix_milli()
		})) or {} // safe to ignore: write failure usually means peer disconnected
		return
	}
	if envelope.type_ == feishu.card_bridge_result_type {
		result := json.decode(feishu.BridgeDispatchResult, raw) or {
			log.error('[bridge] ❌ invalid result frame: ${err}')
			return
		}
		ch := bridge.take_pending(result.request_id) or { return }
		ch <- executor.FeishuCardBridgeResult{
			status:  if result.status > 0 { result.status } else { 200 }
			headers: result.headers.clone()
			body:    result.body
			error:   result.error
		}
		return
	}
	if envelope.type_ != feishu.bridge_proxy_request_type {
		return
	}
	req := json.decode(feishu.BridgeProxyRequest, raw) or {
		log.error('[bridge] ❌ invalid proxy request frame: ${err}')
		return
	}
	log.info('[bridge] 📨 proxy request: request_id=${req.request_id} trace_id=${req.request.metadata['trace_id'] or {
		''
	}} action=${req.action} instance=${req.request.instance} target=${req.request.target} target_type=${req.request.target_type} stream_id=${req.request.metadata['stream_id'] or {
		''
	}} message_type=${req.request.message_type}')
	mut result := feishu.BridgeProxyResult{
		type_:      feishu.bridge_proxy_result_type
		request_id: req.request_id
	}
	match req.action {
		'send' {
			send_result := state.app.websocket_upstream_send(req.request) or {
				result.error = err.msg()
				mut ws_err := unsafe { _ws }
				ws_err.write_string(json.encode(result)) or {} // safe to ignore: write failure usually means peer disconnected
				return
			}
			result.ok = send_result.ok
			result.provider = send_result.provider
			result.instance = send_result.instance
			result.message_id = send_result.message_id
			result.error = send_result.error
			stream_id := (req.request.metadata['stream_id'] or { '' }).trim_space()
			if result.ok && result.message_id.trim_space() != '' && stream_id != '' {
				state.app.providers.feishu.register_stream_buffer(result.message_id, stream_id, if req.request.instance.trim_space() != '' {
					req.request.instance
				} else {
					result.instance
				}, req.request.target, req.request.target_type, req.request.text)
			}
		}
		'update' {
			update_result := state.app.websocket_upstream_update(req.request) or {
				result.error = err.msg()
				mut ws_err := unsafe { _ws }
				ws_err.write_string(json.encode(result)) or {} // safe to ignore: write failure usually means peer disconnected
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
				ws_err.write_string(json.encode(result)) or {} // safe to ignore: write failure usually means peer disconnected
				return
			}
			result.ok = true
			result.provider = 'feishu'
			result.instance = req.request.instance
			result.message_id = req.request.target
		}
		'fail' {
			state.app.providers.feishu.clear_buffer(req.request.target)
			update_result := state.app.websocket_upstream_update(req.request) or {
				result.error = err.msg()
				mut ws_err := unsafe { _ws }
				ws_err.write_string(json.encode(result)) or {} // safe to ignore: write failure usually means peer disconnected
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
	log.info('[bridge] 📤 proxy result: request_id=${req.request_id} trace_id=${req.request.metadata['trace_id'] or {
		''
	}} action=${req.action} ok=${result.ok} message_id=${result.message_id} error=${result.error}')
	ws2.write_string(json.encode(result)) or {
		log.error('[bridge] ❌ failed to send proxy result: ${err}')
	}
}

// C callback trampoline; keep as a free function, see note above.
fn feishu_card_bridge_server_close_cb(mut _ws websocket.Client, _code int, _reason string, ref voidptr) ! {
	mut state := unsafe { &FeishuCardBridgeServerState(ref) }
	mut bridge := state.app.providers.feishu_card_bridge_context()
	bridge.unregister_client(state.client_id)
}

fn FeishuCardBridgeRuntime.handle_server_session(mut app App, mut conn net.TcpConn, key string, client_id string, req_id string) {
	mut server := websocket.new_server(.ip, 0, '')
	mut state := &FeishuCardBridgeServerState{
		app:       unsafe { &app }
		client_id: client_id
	}
	server.on_connect(fn [mut app, state] (mut sc websocket.ServerClient) !bool {
		mut bridge := app.providers.feishu_card_bridge_context()
		bridge.register_client(state.client_id, sc.client)
		return true
	}) or {} // safe to ignore: write failure usually means peer disconnected
	// Keep these as free-function trampolines; see callback note above.
	server.on_message_ref(feishu_card_bridge_server_message_cb, state)
	server.on_close_ref(feishu_card_bridge_server_close_cb, state)
	server.handle_handshake(mut conn, key) or {
		mut bridge := app.providers.feishu_card_bridge_context()
		bridge.unregister_client(client_id)
		log.error('[bridge] ❌ bridge ws handshake failed req=${req_id}: ${err}')
	}
}

@['/bridge/ws'; get]
pub fn (mut app App) feishu_card_bridge_ws(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/bridge/ws' } else { ctx.req.url }
	req_id := HttpRequestIdentity.request_id(ctx, path)
	trace_id := HttpRequestIdentity.trace_id(ctx, path)
	start_ms := time.now().unix_milli()
	request_path, _ := transport.WorkerHttpRequestCodec.normalize_request_target(path)
	normalized_path := transport.WorkerHttpRequestCodec.normalize_path(request_path)
	log.info('[bridge] route feishu_card_bridge_ws path=${path} request_path=${request_path} normalized=${normalized_path} upgrade=${if WebSocketUpgrade.is_upgrade(ctx.req) {
		'true'
	} else {
		'false'
	}}')
	if normalized_path != '/bridge/ws' {
		return feishu_card_bridge_http_response(mut app, mut ctx, 'GET', path, req_id, trace_id,
			start_ms, 404, {
			'content-type': 'text/plain; charset=utf-8'
		}, 'Not Found', 'not_found')
	}
	key := WebSocketUpgrade.key(ctx.req)
	if ctx.req.method.str().to_upper() != 'GET' || key == ''
		|| !WebSocketUpgrade.is_upgrade(ctx.req) {
		return feishu_card_bridge_http_response(mut app, mut ctx, 'GET', path, req_id, trace_id,
			start_ms, 426, {
			'content-type': 'text/plain; charset=utf-8'
			'upgrade':      'websocket'
		}, 'Upgrade Required', 'upgrade_required')
	}
	_, query_string := transport.WorkerHttpRequestCodec.normalize_request_target(path)
	query := transport.WorkerHttpRequestCodec.parse_query_map(query_string)
	client_id := (query['client_id'] or { '' }).trim_space()
	token := (query['token'] or { '' }).trim_space()
	expected := app.providers.feishu.card_bridge_token.trim_space()
	if client_id == '' || (expected != '' && token != expected) {
		return feishu_card_bridge_http_response(mut app, mut ctx, 'GET', path, req_id, trace_id,
			start_ms, 403, {
			'content-type': 'text/plain; charset=utf-8'
		}, 'Forbidden', 'forbidden')
	}
	delivery := feishu_card_bridge_server_session_delivery_outcome(client_id, req_id, trace_id)
	relay_client_id := delivery.metadata['relay_client_id'] or { client_id }
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut conn := ctx.conn
	spawn FeishuCardBridgeRuntime.handle_server_session(mut app, mut conn, key, relay_client_id,
		req_id)
	return veb.no_result()
}
