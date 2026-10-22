module main

import ws
import connection_runtime
import json2 as json
import log
import net
import net.websocket
import time
import executor
import dispatch
import upstream
import upstream.transport
import feishu
import veb

@[heap]
struct FeishuCardBridgeServerState {
mut:
	host      FeishuBridgeProxyHost   @[required]
	bridge    FeishuCardBridgeContext @[required]
	client_id string
	client    ?&websocket.Client
	sender    ?&connection_runtime.WebSocketSender
	watchers  []thread
}

fn (mut state FeishuCardBridgeServerState) reply(payload string) ! {
	mut sender := state.sender or { return error('bridge_connection_unavailable') }
	sender.write_string(payload)!
}

// The session owns closing the accepted connection; the registry only borrows it.
// This also runs when the handshake fails before close callbacks are installed.
fn (mut state FeishuCardBridgeServerState) release_client() {
	owned := state.client
	state.client = none
	writer := state.sender
	state.sender = none
	if mut owner := writer { owner.retire() }
	if mut client := owned {
		state.bridge.unregister_client(state.client_id, client)
		client.close(1000, 'bridge session ended') or {}
	}
	if mut owner := writer { owner.wait_idle() }
	state.watchers.wait()
}

fn feishu_card_bridge_server_connect_cb(mut sc websocket.ServerClient, ref voidptr) !bool {
	mut state := unsafe { &FeishuCardBridgeServerState(ref) }
	state.client = sc.client
	return true
}

fn feishu_card_bridge_server_attached_cb(mut sc websocket.ServerClient, ref voidptr) ! {
	mut state := unsafe { &FeishuCardBridgeServerState(ref) }
	feishu_card_bridge_server_connect_cb(mut sc, ref)!
	// Publish only after the handshake response was written successfully.
	state.sender = state.bridge.register_client(state.client_id, sc.client)
	state.watchers << spawn feishu_bridge_server_watchdog(state.bridge, state.client_id, sc.client)
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
	mut bridge := state.bridge
	if msg.opcode != .text_frame {
		return
	}
	mut authority := bridge.server_authority(state.client_id, &_ws) or { return }
	if !bridge.state.touch_bridge_lease(mut authority) {
		bridge.unregister_client(state.client_id, &_ws)
		if !isnil(_ws.conn) { _ws.conn.close() or {} }
		return
	}
	raw := msg.payload.bytestr()
	envelope := json.decode[feishu.BridgeEnvelope](raw) or {
		log.error('[bridge] ❌ invalid bridge envelope: ${err}')
		return
	}
	if envelope.type_ == feishu.bridge_ping_type {
		hb := json.decode[feishu.BridgeHeartbeatFrame](raw) or { feishu.BridgeHeartbeatFrame{} }
		log.info('[bridge] 💓 heartbeat ping received: request_id=${hb.request_id} trace_id=${hb.trace_id}')
		state.reply(json.encode(feishu.BridgeHeartbeatFrame{
			type_:      feishu.bridge_pong_type
			request_id: hb.request_id
			trace_id:   hb.trace_id
			sent_at:    time.now().unix_milli()
		},
			escape_unicode: true
			time_as_unix:   true
		)) or {} // safe to ignore: write failure usually means peer disconnected
		return
	}
	if envelope.type_ == feishu.card_bridge_result_type {
		result := json.decode[feishu.BridgeDispatchResult](raw) or {
			log.error('[bridge] ❌ invalid result frame: ${err}')
			return
		}
		ch := bridge.take_pending_from(result.request_id, &_ws) or { return }
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
	req := json.decode[feishu.BridgeProxyRequest](raw) or {
		log.error('[bridge] ❌ invalid proxy request frame: ${err}')
		return
	}
	if req.request.provider.trim_space().to_lower() !in ['', 'feishu'] {
		state.reply(json.encode(feishu.BridgeProxyResult{ type_: feishu.bridge_proxy_result_type, request_id: req.request_id, error: 'feishu_bridge_provider_mismatch' })) or {}
		return
	}
	if !bridge.state.bridge_request_allowed(authority, req.action, req.request.metadata['stream_id'] or { '' }, req.request.instance, req.request.metadata['stream_generation'] or { '' }, req.request.target) {
		state.reply(json.encode(feishu.BridgeProxyResult{ type_: feishu.bridge_proxy_result_type, request_id: req.request_id, error: 'bridge_authority_retired' })) or {}
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
		'create' {
			mut owner := state.host.command_feishu_state()
			lease := owner.issue_bridge_creation(mut authority, req.request.metadata['stream_id'] or { '' }, req.request.instance, if req.request.target_type == 'message_id' {
				req.request.target
			} else {
				''
			}, req.request_id) or {
				result.error = err.msg()
				state.reply(json.encode(result, escape_unicode: true, time_as_unix: true)) or {}
				return
			}
			result.ok = true
			result.stream_generation = lease.generation
			result.creation_token = lease.token
		}
		'bind' {
			mut owner := state.host.command_feishu_state()
			owner.mu.@lock()
			generation := owner.publish_bridge_bind_unlocked(authority, req.request.target,
				req.request.metadata['stream_id'] or { '' }, req.request.instance,
				req.request.metadata['stream_generation'] or { '' }, req.request.metadata['source_stream'] or { '' }, req.request.metadata['source_app'] or { '' },
				req.request.metadata['creation_generation'] or { '' }, req.request.metadata['creation_token'] or { '' }) or {
				owner.mu.unlock()
				result.error = 'feishu_stream_command_retired'
				state.reply(json.encode(result)) or {}
				return
			}
			owner.start_sent_publication_unlocked(req.request.target, req.request.metadata['publication_id'] or { '' })
			// The initiating mirror publishes sequence 1 after its local commit.
			owner.next_sent_receipt_unlocked(req.request.target, req.request.target)
			owner.mu.unlock()
			result.ok = true
			result.stream_generation = generation
			result.message_id = req.request.target
		}
		'clear' {
			bridge.release_wire_stream(authority, req.request)
			result.ok = true
		}
		'revoke_creation' {
			mut owner := state.host.command_feishu_state()
			owner.revoke_wire_creation(req.request.metadata['stream_id'] or { '' }, req.request.instance, feishu.CreationLease{
				generation: req.request.metadata['stream_generation'] or { '' }
				token:      req.request.metadata['creation_token'] or { '' }
			})
			result.ok = true
		}
		'send' {
			publication_id := req.request.metadata['publication_id'] or { '' }
			stream_id := (req.request.metadata['stream_id'] or { '' }).trim_space()
			mut feishu_state := state.host.command_feishu_state()
			claim := feishu_state.admit_bridge_initial_creation(authority, stream_id, req.request.instance, req.request.metadata['stream_generation'] or { '' }, req.request.metadata['creation_token'] or { '' }) or {
				result.error = 'feishu_initial_send_retired'
				state.reply(json.encode(result, escape_unicode: true, time_as_unix: true)) or {}
				return
			}
			defer { feishu_state.finish_initial_send(claim) }
			send_result := state.host.websocket_upstream_send(req.request) or {
				result.error = err.msg()
				state.reply(json.encode(result,
					escape_unicode: true
					time_as_unix:   true
				)) or {} // safe to ignore: write failure usually means peer disconnected
				return
			}
			result.ok = send_result.ok
			result.provider = send_result.provider
			result.instance = send_result.instance
			result.message_id = send_result.message_id
			result.error = send_result.error
			if result.ok {
				feishu_state.mu.@lock()
				once := feishu.is_one_shot_reply_stream(stream_id)
				committed := if once {
					feishu_state.complete_initial_reply_unlocked(claim, result.message_id, req.request.metadata['stream_generation'] or { '' })
				} else {
					feishu_state.commit_initial_send_generation_unlocked(claim, result.message_id, if req.request.instance.trim_space() != '' {
						req.request.instance
					} else {
						result.instance
					}, req.request.target, req.request.target_type, req.request.text, req.request.metadata['stream_generation'] or { '' })
				}
				if committed {
					result.stream_generation = req.request.metadata['stream_generation'] or { '' }
				}
				if committed && !once {
					feishu_state.start_sent_publication_unlocked(result.message_id, publication_id)
					feishu_state.next_sent_receipt_unlocked(result.message_id, result.message_id)
					result.stream_generation = feishu_state.stream_generation_unlocked(result.message_id)
				}
				feishu_state.mu.unlock()
				if !committed {
					result.ok = false
					result.error = 'feishu_initial_send_retired'
				}
			}
		}
		'update' {
			mut owner := state.host.command_feishu_state()
			stream := req.request.metadata['stream_id'] or { '' }
			gate := owner.acquire_bridge_stream_gate(req.request.target, stream, req.request.instance, req.request.metadata['stream_generation'] or { '' }) or {
				result.error = 'feishu_message_update_retired'
				state.reply(json.encode(result)) or {}
				return
			}
			defer { gate.release() }
			claim := owner.admit_bridge_message_update(authority, req.request.target, stream, req.request.instance, req.request.metadata['stream_generation'] or { '' }) or {
				result.error = 'feishu_message_update_retired'
				state.reply(json.encode(result)) or {}
				return
			}
			defer { owner.cancel_message_update(claim) }
			if !owner.message_update_is_current(claim) {
				result.error = 'feishu_message_update_retired'
				state.reply(json.encode(result)) or {}
				return
			}
			mut update_request := upstream.UpstreamSendRequest{ ...req.request, metadata: req.request.metadata.clone() }
			update_request.metadata['feishu_update_captured_content'] = claim.buffer.content
			update_result := state.host.websocket_upstream_update(update_request) or {
				result.error = err.msg()
				state.reply(json.encode(result)) or {}
				return
			}
			result.ok = update_result.ok && update_result.message_id == claim.buffer.message_id
			if result.ok { result.ok = owner.complete_message_update(claim) }
			result.provider = update_result.provider
			result.instance = claim.buffer.app
			result.message_id = claim.buffer.message_id
			result.error = if result.ok { '' } else { 'feishu_message_update_retired' }
			if result.ok {
				result.stream_generation = claim.buffer.generation
				result.stream_state = 'message'
			}
		}
		'append', 'finish', 'fail' {
			mut owner := state.host.command_feishu_state()
			stream_id := req.request.metadata['stream_id'] or { '' }
			admission := owner.admit_wire_stream_command(req.request.target, stream_id, req.request.instance, req.request.metadata['stream_generation'] or { '' }) or {
				result.error = 'feishu_stream_command_retired'
				state.reply(json.encode(result, escape_unicode: true, time_as_unix: true)) or {}
				return
			}
			update_result := state.host.feishu_runtime_execute_stream_command(admission, req.request, req.action, (req.request.metadata['feishu_stream_finish'] or { 'true' }) == 'true') or {
				result.error = err.msg()
				state.reply(json.encode(result, escape_unicode: true, time_as_unix: true)) or {}
				return
			}
			if req.action == 'fail' {
				result.stream_state = 'removed'
			} else {
				completed := owner.stream_command_snapshot(admission) or {
					result.error = 'feishu_stream_command_retired'
					state.reply(json.encode(result)) or {}
					return
				}
				result.stream_state = if completed.sealed { 'sealed' } else { 'open' }
			}
			result.stream_generation = req.request.metadata['stream_generation'] or { '' }
			result.ok = update_result.ok
			result.provider = update_result.provider
			result.instance = update_result.instance
			result.message_id = req.request.target
			result.error = update_result.error
		}
		else {
			result.error = 'unsupported_proxy_action:${req.action}'
		}
	}

	log.info('[bridge] 📤 proxy result: request_id=${req.request_id} trace_id=${req.request.metadata['trace_id'] or {
		''
	}} action=${req.action} ok=${result.ok} message_id=${result.message_id} error=${result.error}')
	state.reply(json.encode(result,
		escape_unicode: true
		time_as_unix:   true
	)) or {
		log.error('[bridge] ❌ failed to send proxy result: ${err}')
	}
}

// C callback trampoline; keep as a free function, see note above.
fn feishu_card_bridge_server_close_cb(mut _ws websocket.Client, _code int, _reason string, ref voidptr) ! {
	mut state := unsafe { &FeishuCardBridgeServerState(ref) }
	mut bridge := state.bridge
	bridge.unregister_client(state.client_id, &_ws)
}

fn FeishuCardBridgeRuntime.handle_server_session(mut host FeishuBridgeProxyHost, mut conn net.TcpConn, key string, client_id string, req_id string) {
	mut server, captured := ws.managed_server()
	mut state := &FeishuCardBridgeServerState{
		host:      host
		bridge:    host.bridge_context()
		client_id: client_id
	}
	defer {
		state.release_client()
	}

	server.on_attached_ref(feishu_card_bridge_server_attached_cb, state)
	// Keep these as free-function trampolines; see callback note above.
	server.on_message_ref(feishu_card_bridge_server_message_cb, state)
	server.on_close_ref(feishu_card_bridge_server_close_cb, state)
	ws.managed_handshake(mut server, mut conn, key, captured) or {
		log.error('[bridge] ❌ bridge ws handshake failed req=${req_id}: ${err}')
	}
}

@['/bridge/ws'; get]
pub fn (mut app App) feishu_card_bridge_ws(mut ctx Context) veb.Result {
	raw_path := if ctx.req.url == '' { '/bridge/ws' } else { ctx.req.url }
	path, _ := transport.WorkerHttpRequestCodec.normalize_request_target(raw_path)
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
	_, query_string := transport.WorkerHttpRequestCodec.normalize_request_target(raw_path)
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
	mut run := reserve_inbound_websocket(mut app, ctx) or { return inbound_websocket_unavailable(mut ctx) }
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut conn := ctx.conn
	spawn FeishuCardBridgeRuntime.run_server_session(mut run, mut app, mut conn, key, relay_client_id,
		req_id)
	return veb.no_result()
}

fn FeishuCardBridgeRuntime.run_server_session(mut run ws.IngressRun, mut host FeishuBridgeProxyHost, mut conn net.TcpConn, key string, client_id string, req_id string) {
	defer { run.finish() }
	if run.stopped() {
		conn.close() or {}
		return
	}
	FeishuCardBridgeRuntime.handle_server_session(mut host, mut conn, key, client_id, req_id)
}

fn feishu_bridge_server_watchdog(context FeishuCardBridgeContext, client_id string, client &websocket.Client) {
	mut bridge := context
	for {
		time.sleep(time.second)
		authority := bridge.server_authority(client_id, client) or { return }
		if !bridge.state.bridge_lease_expired(authority) { continue }
		bridge.unregister_client(client_id, client)
		if !isnil(client.conn) { client.conn.close() or {} }
		return
	}
}
