module main

import api.openai
import command
import json2 as json
import executor
import feishu
import net.websocket
import net
import time
import upstream
import upstream.transport

fn test_generic_command_handler_needs_only_message_and_restart_capabilities() {
	mut host := &NarrowCommandBridgeHost{}
	handler := GenericUpstreamCommandHandler.new(mut host)
	cmd := transport.WorkerWebSocketUpstreamCommand{ type_: 'discord.message.send' }
	mut snapshot := executor.WebSocketUpstreamCommandActivity{}
	handled, err := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut snapshot)
	assert handled && err == ''
	assert snapshot.message_id == 'first'
	host.message_id = 'second'
	handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut snapshot)
	assert snapshot.message_id == 'second'
	assert host.sent == 2
	restart := transport.WorkerWebSocketUpstreamCommand{ type_: 'admin.worker.restart_all' }
	handler.execute(restart, command.NormalizedCommand.from_worker_command(restart), mut snapshot)
	assert snapshot.status == 'restarted'
	assert snapshot.target == '3'
}

fn test_bridge_callback_contexts_keep_live_state_without_app() {
	mut host := &NarrowCommandBridgeHost{}
	mut bridge := host.bridge_context()
	mut client := websocket.new_client('ws://localhost:12345') or { panic(err) }
	mut state := &FeishuCardBridgeClientState{ host: host, bridge: bridge }
	ch := chan feishu.BridgeProxyResult{cap: 1}
	sender := bridge.set_client_conn(client)
	lane := &FeishuBridgeDispatchLane{ sender: sender, jobs: chan FeishuBridgeDispatchJob{cap: 16} }
	state.dispatch_lane = lane
	request_id := bridge.register_proxy_pending(ch) or { panic(err) }
	feishu_card_bridge_client_message_cb(mut client, &websocket.Message{
		opcode:  .text_frame
		payload: json.encode(feishu.BridgeProxyResult{ type_: feishu.bridge_proxy_result_type, request_id: request_id, ok: true }).bytes()
	}, state) or { panic(err) }
	if pending := bridge.take_proxy_pending(request_id) {
		_ = pending
		panic('proxy result not routed')
	}
	result := <-ch
	assert result.ok
	feishu_card_bridge_client_message_cb(mut client, &websocket.Message{
		opcode:  .text_frame
		payload: json.encode(feishu.BridgeDispatchRequest{
			type_:      feishu.card_bridge_request_type
			request_id: 'callback'
		}).bytes()
	}, state) or { panic(err) }
	job := <-lane.jobs
	FeishuCardBridgeRuntime.dispatch_job(mut state.host, bridge, job)
	assert host.dispatched == 1
	bridge.set_client_conn(client)
	feishu_card_bridge_client_error_cb(mut client, 'test error', state) or { panic(err) }
	assert host.state.card_bridge_client_conn == none
	bridge.set_client_conn(client)
	feishu_card_bridge_client_close_cb(mut client, 1000, 'done', state) or { panic(err) }
	assert host.state.card_bridge_client_conn == none
	bridge.register_client('client', client)
	lease := host.state.issue_wire_creation('bridge-test', 'main') or { panic(err) }
	server_state := &FeishuCardBridgeServerState{ host: host, bridge: bridge, client_id: 'client' }
	feishu_card_bridge_server_message_cb(mut client, &websocket.Message{
		opcode:  .text_frame
		payload: json.encode(feishu.BridgeProxyRequest{
			type_:      feishu.bridge_proxy_request_type
			request_id: 'proxy'
			action:     'send'
			request:    upstream.UpstreamSendRequest{
				provider:    'feishu'
				instance:    'main'
				target:      'chat'
				target_type: 'chat_id'
				metadata:    {
					'stream_id':         'bridge-test'
					'stream_generation': lease.generation
					'creation_token':    lease.token
				}
			}
		}).bytes()
	}, server_state) or { panic(err) }
	assert host.sent == 1
	feishu_card_bridge_server_close_cb(mut client, 1000, 'done', server_state) or { panic(err) }
	assert 'client' !in host.state.card_bridge_clients
}

struct NarrowFrameMapper {}

fn (mut _ NarrowFrameMapper) openai_plugin_map_frame(_plan openai.OpenAIResolvedPlan, frame string, _request string, _trace string) !openai.OpenAIFrameMapping {
	return openai.OpenAIFrameMapping{ handled: true, content: frame }
}

fn test_openai_frame_mapper_uses_optional_narrow_host() {
	mut state := OpenAIMappedStreamProxyState{}
	missing := state.map_line_with_plugin('frame')
	assert missing.error == 'openai_frame_mapper_host_missing'
	state.mapper_host = NarrowFrameMapper{}
	assert state.map_line_with_plugin('frame').content == 'frame'
}

fn test_bridge_stale_unregister_preserves_replacement() {
	mut host := &NarrowCommandBridgeHost{}
	mut bridge := host.bridge_context()
	first := websocket.new_client('ws://localhost:1') or { panic(err) }
	second := websocket.new_client('ws://localhost:2') or { panic(err) }
	bridge.register_client('same', first)
	bridge.register_client('same', second)
	bridge.unregister_client('same', first)
	assert voidptr(bridge.client('same') or { panic('replacement removed') }) == voidptr(second)
	bridge.unregister_client('same', second)
	bridge.unregister_client('same', first)
	bridge.unregister_client('same', second)
	assert bridge.client('same') == none
}

fn test_bridge_send_failure_retires_current_registration() {
	mut host := &NarrowCommandBridgeHost{}
	mut bridge := host.bridge_context()
	client := websocket.new_client('ws://localhost:1') or { panic(err) }
	bridge.register_client('same', client)
	assert !bridge.send('same', 'closed socket')
	assert bridge.client('same') == none
	assert !bridge.send('same', 'already removed')
}

fn test_bridge_stale_close_callback_preserves_replacement() {
	mut host := &NarrowCommandBridgeHost{}
	mut bridge := host.bridge_context()
	mut first := websocket.new_client('ws://localhost:1') or { panic(err) }
	second := websocket.new_client('ws://localhost:2') or { panic(err) }
	state := &FeishuCardBridgeServerState{ host: host, bridge: bridge, client_id: 'same' }
	bridge.register_client('same', second)
	feishu_card_bridge_server_close_cb(mut first, 1000, 'late close', state) or { panic(err) }
	assert voidptr(bridge.client('same') or { panic('replacement removed') }) == voidptr(second)
}

fn test_bridge_failed_handshake_does_not_publish_or_remove_live_client() {
	mut host := &NarrowCommandBridgeHost{}
	mut bridge := host.bridge_context()
	first := websocket.new_client('ws://localhost:1') or { panic(err) }
	second := websocket.new_client('ws://localhost:2') or { panic(err) }
	bridge.register_client('same', second)
	mut state := &FeishuCardBridgeServerState{ host: host, bridge: bridge, client_id: 'same' }
	// Failure before the accept callback must leave the live registry untouched.
	state.release_client()
	mut sc := websocket.ServerClient{ client: first }
	assert feishu_card_bridge_server_connect_cb(mut sc, state) or { panic(err) }
	assert voidptr(bridge.client('same') or { panic('live client removed') }) == voidptr(second)
	// Failure while writing 101 owns the first handle, but has not published it.
	state.release_client()
	state.release_client()
	assert state.client == none
	assert voidptr(bridge.client('same') or { panic('live client removed') }) == voidptr(second)
}

fn test_bridge_attached_session_release_removes_only_owned_registration() {
	mut host := &NarrowCommandBridgeHost{}
	mut bridge := host.bridge_context()
	first := websocket.new_client('ws://localhost:1') or { panic(err) }
	second := websocket.new_client('ws://localhost:2') or { panic(err) }
	mut state := &FeishuCardBridgeServerState{ host: host, bridge: bridge, client_id: 'same' }
	mut sc := websocket.ServerClient{ client: first }
	assert feishu_card_bridge_server_connect_cb(mut sc, state) or { panic(err) }
	assert bridge.client('same') == none
	feishu_card_bridge_server_attached_cb(mut sc, state) or { panic(err) }
	assert voidptr(bridge.client('same') or { panic('client not published') }) == voidptr(first)
	bridge.register_client('same', second)
	state.release_client()
	assert voidptr(bridge.client('same') or { panic('replacement removed') }) == voidptr(second)
	mut next := &FeishuCardBridgeServerState{ host: host, bridge: bridge, client_id: 'same', client: second }
	next.release_client()
	assert bridge.client('same') == none
}

fn run_bridge_session_fixture(mut host NarrowCommandBridgeHost, mut listener net.TcpListener, done chan bool) {
	mut conn := listener.accept() or {
		done <- false
		return
	}
	conn.set_write_timeout(time.second)
	conn.set_read_timeout(time.second)
	FeishuCardBridgeRuntime.handle_server_session(mut host, mut conn, 'dGhlIHNhbXBsZSBub25jZQ==', 'same', 'test')
	done <- true
}

fn test_bridge_socket_eof_releases_session_without_erasing_reconnect() {
	mut host := &NarrowCommandBridgeHost{}
	mut bridge := host.bridge_context()
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	done := chan bool{cap: 1}
	spawn run_bridge_session_fixture(mut host, mut listener, done)
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	defer { peer.close() or {} }
	peer.set_read_timeout(time.second)
	mut response := []u8{len: 1024}
	n := peer.read(mut response) or { panic(err) }
	assert response[..n].bytestr().contains('101 Switching Protocols')
	deadline := time.now().add(time.second)
	for !bridge.has_client('same') && time.now() < deadline { time.sleep(time.millisecond) }
	assert bridge.has_client('same')
	old := bridge.client('same') or { panic('missing connected client') }
	replacement := websocket.new_client('ws://localhost:2') or { panic(err) }
	bridge.register_client('same', replacement)
	peer.close() or { panic(err) }
	select {
		ok := <-done {
			assert ok
		}
		3 * time.second {
			panic('bridge session failed to stop after EOF')
		}
	}
	assert old.get_state() == .closed
	assert voidptr(bridge.client('same') or { panic('replacement removed by EOF') }) == voidptr(replacement)
}

fn test_bridge_callbacks_ignore_late_results_and_keep_current_waiters() {
	mut host := &NarrowCommandBridgeHost{}
	mut bridge := host.bridge_context()
	mut client := websocket.new_client('ws://localhost:12345') or { panic(err) }
	mut server := &FeishuCardBridgeServerState{ host: host, bridge: bridge, client_id: 'same' }
	mut outbound := &FeishuCardBridgeClientState{ host: host, bridge: bridge }
	bridge.register_client('same', client)
	bridge.set_client_conn(client)
	for proxy in [false, true] {
		old_ch := chan executor.FeishuCardBridgeResult{cap: 1}
		new_ch := chan executor.FeishuCardBridgeResult{cap: 1}
		old_proxy := chan feishu.BridgeProxyResult{cap: 1}
		new_proxy := chan feishu.BridgeProxyResult{cap: 1}
		old_id := if proxy {
			bridge.register_proxy_pending(old_proxy) or { panic(err) }
		} else {
			bridge.register_pending(old_ch, 'same') or { panic(err) }
		}
		new_id := if proxy {
			bridge.register_proxy_pending(new_proxy) or { panic(err) }
		} else {
			bridge.register_pending(new_ch, 'same') or { panic(err) }
		}
		// Model timeout cleanup before the response arrives; then deliver late,
		// current and duplicate frames through the actual callback path.
		if proxy {
			assert bridge.take_proxy_pending(old_id) != none
		} else {
			assert bridge.take_pending(old_id) != none
		}
		for id in [old_id, new_id, new_id] {
			payload := if proxy {
				json.encode(feishu.BridgeProxyResult{ type_: feishu.bridge_proxy_result_type, request_id: id, message_id: 'current' })
			} else {
				json.encode(feishu.BridgeDispatchResult{ type_: feishu.card_bridge_result_type, request_id: id, body: 'current' })
			}
			msg := &websocket.Message{ opcode: .text_frame, payload: payload.bytes() }
			if proxy {
				feishu_card_bridge_client_message_cb(mut client, msg, outbound) or { panic(err) }
			} else {
				feishu_card_bridge_server_message_cb(mut client, msg, server) or { panic(err) }
			}
		}
		if proxy {
			select {
				result := <-new_proxy {
					assert result.message_id == 'current'
				}
				time.second {
					panic('current proxy result was not delivered')
				}
			}
		} else {
			select {
				result := <-new_ch {
					assert result.body == 'current'
				}
				time.second {
					panic('current callback result was not delivered')
				}
			}
		}
	}
	assert host.state.card_bridge_pending.len == 0
	assert host.state.card_bridge_proxy_pending.len == 0
}

fn test_bridge_dispatch_lane_is_bounded_and_stale_jobs_cannot_cross_connections() {
	mut host := &NarrowCommandBridgeHost{}
	mut bridge := host.bridge_context()
	mut old := websocket.new_client('ws://localhost:1') or { panic(err) }
	old_sender := bridge.set_client_conn(old)
	mut lane := &FeishuBridgeDispatchLane{ sender: old_sender, jobs: chan FeishuBridgeDispatchJob{cap: 1} }
	mut state := &FeishuCardBridgeClientState{ host: host, bridge: bridge, sender: old_sender, dispatch_lane: lane }
	for id in ['accepted', 'overflow'] {
		feishu_card_bridge_client_message_cb(mut old, &websocket.Message{ opcode: .text_frame, payload: json.encode(feishu.BridgeDispatchRequest{ type_: feishu.card_bridge_request_type, request_id: id }).bytes() }, state) or { panic(err) }
	}
	assert lane.jobs.len == 1 && host.dispatched == 0
	mut current := websocket.new_client('ws://localhost:2') or { panic(err) }
	sender := bridge.set_client_conn(current)
	stale := <-lane.jobs
	FeishuCardBridgeRuntime.dispatch_job(mut state.host, bridge, stale)
	assert host.dispatched == 0 && bridge.client_conn() != none
	lane.close(bridge)
	current_lane := &FeishuBridgeDispatchLane{ sender: sender, jobs: chan FeishuBridgeDispatchJob{cap: 1} }
	state.dispatch_lane = current_lane
	feishu_card_bridge_client_message_cb(mut current, &websocket.Message{ opcode: .text_frame, payload: json.encode(feishu.BridgeDispatchRequest{ type_: feishu.card_bridge_request_type, request_id: 'current' }).bytes() }, state) or { panic(err) }
	mut owner := bridge.client_authority(current) or { panic('owner') }
	bridge.state.note_bridge_creation_capacity(mut owner)
	bridge.rotate_creation_capacity_if_idle()
	assert bridge.client_conn() != none
	job := <-current_lane.jobs
	FeishuCardBridgeRuntime.dispatch_job(mut state.host, bridge, job)
	assert host.dispatched == 1
	assert bridge.client_conn() == none
}
