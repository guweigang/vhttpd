module main

import connection_runtime
import executor
import feishu
import json2 as json
import net
import net.websocket
import time

fn queue_callback(mut state FeishuCardBridgeClientState, mut client websocket.Client, id string) {
	feishu_card_bridge_client_message_cb(mut client, &websocket.Message{ opcode: .text_frame, payload: json.encode(feishu.BridgeDispatchRequest{ type_: feishu.card_bridge_request_type, request_id: id }).bytes() }, state) or { panic(err) }
}

fn queue_hold_writer(mut sender connection_runtime.WebSocketSender) {
	sender.write_string('x'.repeat(8 * 1024 * 1024)) or {}
}

fn queue_callback_done(mut state FeishuCardBridgeClientState, mut client websocket.Client, done chan bool) {
	queue_callback(mut state, mut client, 'overflow')
	done <- true
}

// Also runs unchanged against the pre-fix production snapshot.
fn test_queue_full_reader_does_not_wait_for_a_busy_socket_writer() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	mut peer := net.dial_tcp((listener.addr() or { panic(err) }).str()) or { panic(err) }
	defer { peer.close() or {} }
	mut host := &NarrowCommandBridgeHost{}
	mut bridge := host.bridge_context()
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = listener.accept() or { panic(err) }
	client.set_state(.open)
	defer { client.conn.close() or {} }
	sender := bridge.set_client_conn(client)
	lane := &FeishuBridgeDispatchLane{ sender: sender, jobs: chan FeishuBridgeDispatchJob{cap: 1} }
	mut state := &FeishuCardBridgeClientState{ host: host, bridge: bridge, sender: sender, dispatch_lane: lane }
	queue_callback(mut state, mut client, 'first')
	mut session := connection_runtime.Session.connected(client) or { panic(err) }
	defer { session.release() }
	mut writer := sender
	done := chan bool{cap: 1}
	blocker := spawn queue_hold_writer(mut writer)
	// Reading the frame header proves the writer has entered the real socket IO;
	// leave its large body unread so the kernel applies backpressure.
	peer.set_read_timeout(2 * time.second)
	mut header := []u8{len: 16}
	assert peer.read(mut header) or { 0 } > 0
	callback := spawn queue_callback_done(mut state, mut client, done)
	mut prompt := false
	select {
		_ := <-done {
			prompt = true
		}
		250 * time.millisecond {
		}
	}
	session.request_stop()
	blocker.wait()
	callback.wait()
	assert prompt, 'queue overflow blocked the socket reader behind another writer'
}

fn queue_produce(mut state FeishuCardBridgeClientState, mut client websocket.Client) {
	for i in 0 .. 64 { queue_callback(mut state, mut client, 'race-${i}') }
}

fn test_queue_closure_excludes_late_admission_and_releases_all_queued_leases() {
	mut host := &NarrowCommandBridgeHost{}
	mut bridge := host.bridge_context()
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	sender := bridge.set_client_conn(client)
	mut lane := &FeishuBridgeDispatchLane{ sender: sender, jobs: chan FeishuBridgeDispatchJob{cap: 128} }
	mut state := &FeishuCardBridgeClientState{ host: host, bridge: bridge, sender: sender, dispatch_lane: lane }
	producer := spawn queue_produce(mut state, mut client)
	lane.close(bridge)
	producer.wait()
	queue_callback(mut state, mut client, 'after-close')
	assert lane.jobs.len == 0 && lane.rejections.len == 0
	mut owner := bridge.client_authority(client) or { panic('owner') }
	bridge.state.note_bridge_creation_capacity(mut owner)
	bridge.rotate_creation_capacity_if_idle()
	assert bridge.client_conn() == none, 'closed queue leaked a dispatch lease'
}

fn test_rejection_queue_is_bounded_and_saturation_retires_only_its_connection() {
	mut host := &NarrowCommandBridgeHost{}
	mut bridge := host.bridge_context()
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	sender := bridge.set_client_conn(client)
	mut lane := &FeishuBridgeDispatchLane{ sender: sender, jobs: chan FeishuBridgeDispatchJob{cap: 1}, rejections: chan FeishuBridgeDispatchJob{cap: 1} }
	mut state := &FeishuCardBridgeClientState{ host: host, bridge: bridge, sender: sender, dispatch_lane: lane }
	queue_callback(mut state, mut client, 'accepted')
	queue_callback(mut state, mut client, 'rejected')
	assert lane.jobs.len == 1 && lane.rejections.len == 1 && bridge.client_conn() != none
	queue_callback(mut state, mut client, 'saturated')
	assert lane.jobs.len == 0 && lane.rejections.len == 0 && bridge.client_conn() == none
	mut current := websocket.new_client('ws://localhost:2') or { panic(err) }
	bridge.set_client_conn(current)
	lane.abort(bridge)
	queue_callback(mut state, mut client, 'late')
	assert bridge.client_authority(current) != none && lane.jobs.len == 0
}

@[heap]
struct QueueWaitingHost {
mut:
	state     feishu.FeishuState
	started   chan bool   = chan bool{cap: 1}
	completed chan string = chan string{cap: 1}
}

fn (mut h QueueWaitingHost) bridge_context() FeishuCardBridgeContext {
	return FeishuCardBridgeContext{ state: &h.state }
}

fn (mut h QueueWaitingHost) bridge_dispatch_request(_ feishu.BridgeDispatchRequest, _ string) !executor.KernelWebSocketUpstreamDispatchOutcome {
	mut bridge := h.bridge_context()
	ch := chan feishu.BridgeProxyResult{cap: 1}
	_ := bridge.register_proxy_pending(ch)!
	h.started <- true
	result := <-ch
	h.completed <- result.error
	return executor.KernelWebSocketUpstreamDispatchOutcome{}
}

fn queue_join(workers []thread, done chan bool) {
	workers.wait()
	done <- true
}

fn test_session_stop_cancels_active_rpc_and_drains_both_callback_queues_before_join() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	mut peer := net.dial_tcp((listener.addr() or { panic(err) }).str()) or { panic(err) }
	defer { peer.close() or {} }
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = listener.accept() or { panic(err) }
	client.set_state(.open)
	defer { client.conn.close() or {} }
	mut session := connection_runtime.Session.connected(client) or { panic(err) }
	defer { session.release() }
	mut host := &QueueWaitingHost{}
	mut bridge := host.bridge_context()
	sender := bridge.set_client_conn(client)
	mut lane := &FeishuBridgeDispatchLane{ sender: sender, session: session, jobs: chan FeishuBridgeDispatchJob{cap: 1} }
	mut state := &FeishuCardBridgeClientState{ host: host, bridge: bridge, sender: sender, dispatch_lane: lane }
	mut workers := []thread{}
	workers << spawn FeishuCardBridgeRuntime.client_dispatch_loop(mut state, mut lane, mut session)
	workers << spawn feishu_bridge_client_watchdog(bridge, mut lane, mut session, client)
	queue_callback(mut state, mut client, 'active')
	_ := <-host.started
	queue_callback(mut state, mut client, 'queued')
	queue_callback(mut state, mut client, 'rejected')
	assert lane.jobs.len == 1 && lane.rejections.len == 1
	session.request_stop()
	done := chan bool{cap: 1}
	joined := spawn queue_join(workers, done)
	mut prompt := false
	select {
		_ := <-done {
			prompt = true
		}
		time.second {
		}
	}
	if !prompt { bridge.clear_client_conn(client) }
	joined.wait()
	assert prompt, 'session worker join waited for an RPC whose reader had stopped'
	assert (<-host.completed) == 'bridge_connection_closed'
	assert lane.jobs.len == 0 && lane.rejections.len == 0
	assert bridge.state.card_bridge_proxy_pending.len == 0 && bridge.client_conn() == none
}

fn test_watchdog_withdrawal_stops_old_workers_without_erasing_replacement() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	mut peer := net.dial_tcp((listener.addr() or { panic(err) }).str()) or { panic(err) }
	defer { peer.close() or {} }
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = listener.accept() or { panic(err) }
	client.set_state(.open)
	defer { client.conn.close() or {} }
	mut session := connection_runtime.Session.connected(client) or { panic(err) }
	defer { session.release() }
	mut host := &NarrowCommandBridgeHost{}
	mut bridge := host.bridge_context()
	sender := bridge.set_client_conn(client)
	mut lane := &FeishuBridgeDispatchLane{ sender: sender, session: session, jobs: chan FeishuBridgeDispatchJob{cap: 1} }
	mut state := &FeishuCardBridgeClientState{ host: host, bridge: bridge, sender: sender, dispatch_lane: lane }
	queue_callback(mut state, mut client, 'old')
	queue_callback(mut state, mut client, 'old-rejection')
	mut current := websocket.new_client('ws://localhost:2') or { panic(err) }
	bridge.set_client_conn(current)
	worker := spawn feishu_bridge_client_watchdog(bridge, mut lane, mut session, client)
	worker.wait()
	assert session.stopped(), 'watchdog withdrawal left reader and queue workers running'
	assert lane.jobs.len == 0 && lane.rejections.len == 0
	assert bridge.client_authority(current) != none
}
