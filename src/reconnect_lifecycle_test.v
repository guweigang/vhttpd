module main

import connection_runtime
import executor
import feishu
import io
import net
import net.http
import net.websocket
import time

@[heap]
struct ReconnectBridgeHost {
mut:
	state feishu.FeishuState
}

fn (mut h ReconnectBridgeHost) bridge_context() FeishuCardBridgeContext { return FeishuCardBridgeContext{state: &h.state} }
fn (mut _ ReconnectBridgeHost) bridge_dispatch_request(_ feishu.BridgeDispatchRequest, _ string) !executor.KernelWebSocketUpstreamDispatchOutcome { return executor.KernelWebSocketUpstreamDispatchOutcome{} }

fn reconnect_signal(ch chan bool) { select { _ := <-ch {} 3 * time.second { panic('reconnect fixture timed out') } } }

fn reconnect_capture_message(mut _ websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &ReconnectMessageState(ref) }
	if msg.opcode == .text_frame { state.messages <- msg.payload.bytestr() }
}

@[heap]
struct ReconnectMessageState { messages chan string }

fn reconnect_server(mut listener net.TcpListener, done chan bool, messages chan string, count int) {
	for _ in 0 .. count {
		mut conn := listener.accept() or { done <- false; return }
		conn.set_read_timeout(3 * time.second)
		conn.set_write_timeout(time.second)
		mut reader := io.new_buffered_reader(reader: conn)
		req := http.parse_request(mut reader) or { conn.close() or {}; done <- false; return }
		key := req.header.get(.sec_websocket_key) or { conn.close() or {}; done <- false; return }
		mut server := websocket.new_server(.ip, 0, '')
		state := &ReconnectMessageState{messages: messages}
		server.on_message_ref(reconnect_capture_message, state)
		server.handle_handshake(mut conn, key) or {}
		conn.close() or {}
		done <- true
	}
}

fn test_bridge_stop_cancels_retry_and_allows_restart() {
	mut host := &ReconnectBridgeHost{}
	host.state.card_bridge_enabled_flag = true
	host.state.card_bridge_ws_url = 'ws://127.0.0.1:1/'
	for _ in 0 .. 3 {
		assert FeishuCardBridgeRuntime.start_client(mut host)
		assert !FeishuCardBridgeRuntime.start_client(mut host)
		host.state.background_runs.stop_prefix('')
		mut bridge := host.bridge_context()
		assert bridge.client_conn() == none
	}
}

fn test_live_bridge_stop_joins_heartbeat_clears_handle_and_reconnects() {
	mut host := &ReconnectBridgeHost{}
	mut bridge := host.bridge_context()
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	host.state.card_bridge_enabled_flag = true
	host.state.card_bridge_ws_url = 'ws://${addr}/bridge/ws'
	host.state.card_bridge_client_id = 'owned-client'
	done := chan bool{cap: 2}
	messages := chan string{cap: 10}
	spawn reconnect_server(mut listener, done, messages, 2)
	for _ in 0 .. 2 {
		assert FeishuCardBridgeRuntime.start_client(mut host)
		deadline := time.now().add(3 * time.second)
		for bridge.client_conn() == none { assert time.now() < deadline; time.sleep(time.millisecond) }
		old := bridge.client_conn() or { panic('missing connected bridge') }
		host.state.background_runs.stop_prefix('')
		reconnect_signal(done)
		assert old.get_state() == .closed
		assert bridge.client_conn() == none
	}
}

fn test_codex_stop_during_initialize_joins_workers_without_late_attachment() {
	mut app := &App{}
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	done := chan bool{cap: 1}
	messages := chan string{cap: 10}
	spawn reconnect_server(mut listener, done, messages, 1)
	mut client := websocket.new_client('ws://${addr}/', read_timeout: 3 * time.second) or { panic(err) }
	client.connect() or { panic(err) }
	mut session := connection_runtime.Session.connected(client) or { panic(err) }
	mut workers := app.provider_websocket_post_connect('codex', 'main', 'ws://${addr}/', mut session, mut client)
	select { message := <-messages { assert message.contains('"method":"initialize"') } 3 * time.second { panic('no initialize') } }
	session.request_stop()
	workers.wait()
	connection_runtime.close_client(mut client)
	session.release()
	reconnect_signal(done)
	assert app.providers.codex.snapshot('main').connection() == none
	select { message := <-messages { panic('late handshake write: ${message}') } else {} }
}

fn test_feishu_buffer_flusher_is_owned_and_provider_stop_waits() {
	mut app := &App{}
	app.providers.feishu.enabled = true
	ProviderStartupRuntime.start_feishu_background(mut app)
	assert app.providers.feishu.background_runs.reserve('buffer-flusher') == none
	ctx := app.build_provider_context('feishu')
	ctx.stop() or { panic(err) }
	assert app.providers.feishu.background_runs.reserve('buffer-flusher') == none // Provider remains stopped until start.
	assert app.websocket.upstream_runs.reserve('feishu/main') == none
	ctx.start() or { panic(err) }
	mut probe := app.websocket.upstream_runs.reserve('feishu/main') or { panic('provider did not resume upstreams') }
	app.websocket.upstream_runs.release('feishu/main', mut probe)
	ctx.stop() or { panic(err) }
}

fn test_codex_initialize_write_failure_stops_session_for_reconnect() {
	mut app := &App{}
	mut client := websocket.new_client('ws://127.0.0.1:1/') or { panic(err) }
	mut session := connection_runtime.Session{}
	app.codex_post_connect_handshake('main', mut session, mut client)
	assert session.stopped()
	assert session.disconnect_reason().starts_with('handshake:initialize:')
	assert app.providers.codex.snapshot('main').connection() == none
}
