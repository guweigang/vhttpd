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

// Implements only the generic command and bridge capabilities used below.
@[heap]
struct NarrowCommandBridgeHost {
mut:
	state      feishu.FeishuState
	sent       int
	dispatched int
	message_id string = 'first'
}

fn (mut h NarrowCommandBridgeHost) websocket_upstream_send(_req upstream.UpstreamSendRequest) !upstream.UpstreamSendResult {
	h.sent++
	return upstream.UpstreamSendResult{ ok: true, message_id: h.message_id }
}

fn (mut h NarrowCommandBridgeHost) websocket_upstream_update(_req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	return upstream.UpstreamUpdateResult{ ok: true, message_id: h.message_id }
}

fn (mut _ NarrowCommandBridgeHost) restart_all_workers() int { return 3 }

fn (mut h NarrowCommandBridgeHost) bridge_context() FeishuCardBridgeContext {
	return FeishuCardBridgeContext{ state: &h.state }
}

fn (mut h NarrowCommandBridgeHost) bridge_dispatch_request(_req feishu.BridgeDispatchRequest, _kind string) !executor.KernelWebSocketUpstreamDispatchOutcome {
	h.dispatched++
	return executor.KernelWebSocketUpstreamDispatchOutcome{}
}

fn (mut h NarrowCommandBridgeHost) command_feishu_state() &feishu.FeishuState { return &h.state }

fn (mut _ NarrowCommandBridgeHost) feishu_runtime_buffer_patch(_req upstream.UpstreamSendRequest) {}

fn (mut _ NarrowCommandBridgeHost) feishu_runtime_flush_buffer(_id string, _content string, _finish bool) ! {}

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
	assert host.dispatched == 1
	bridge.set_client_conn(client)
	feishu_card_bridge_client_error_cb(mut client, 'test error', state) or { panic(err) }
	assert host.state.card_bridge_client_conn == none
	bridge.set_client_conn(client)
	feishu_card_bridge_client_close_cb(mut client, 1000, 'done', state) or { panic(err) }
	assert host.state.card_bridge_client_conn == none
	bridge.register_client('client', client)
	server_state := &FeishuCardBridgeServerState{ host: host, bridge: bridge, client_id: 'client' }
	feishu_card_bridge_server_message_cb(mut client, &websocket.Message{
		opcode:  .text_frame
		payload: json.encode(feishu.BridgeProxyRequest{
			type_:      feishu.bridge_proxy_request_type
			request_id: 'proxy'
			action:     'send'
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
	mut server := &FeishuCardBridgeServerState{ host: host, bridge: bridge }
	mut outbound := &FeishuCardBridgeClientState{ host: host, bridge: bridge }
	for proxy in [false, true] {
		old_ch := chan executor.FeishuCardBridgeResult{cap: 1}
		new_ch := chan executor.FeishuCardBridgeResult{cap: 1}
		old_proxy := chan feishu.BridgeProxyResult{cap: 1}
		new_proxy := chan feishu.BridgeProxyResult{cap: 1}
		old_id := if proxy {
			bridge.register_proxy_pending(old_proxy) or { panic(err) }
		} else {
			bridge.register_pending(old_ch) or { panic(err) }
		}
		new_id := if proxy {
			bridge.register_proxy_pending(new_proxy) or { panic(err) }
		} else {
			bridge.register_pending(new_ch) or { panic(err) }
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
			assert (<-new_proxy).message_id == 'current'
		} else {
			assert (<-new_ch).body == 'current'
		}
	}
	assert host.state.card_bridge_pending.len == 0
	assert host.state.card_bridge_proxy_pending.len == 0
}
