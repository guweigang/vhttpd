module main

import executor
import net
import net.websocket
import relay
import runtime_plan
import time
import upstream.transport
import ws

struct CarrierTargetExecutor {
	app         &App                  @[required]
	replacement &ws.DispatchConnState @[required]
}

fn (e CarrierTargetExecutor) model() executor.LogicExecutorModel {
	_ = e
	return .worker
}

fn (e CarrierTargetExecutor) kind() string {
	_ = e
	return 'relay-mcp-test'
}

fn (e CarrierTargetExecutor) provider() string {
	_ = e
	return 'relay-mcp-test'
}

fn (e CarrierTargetExecutor) admin_details() executor.LogicExecutorAdminDetails {
	_ = e
	return executor.LogicExecutorAdminDetails{
		kind:     'relay-mcp-test'
		provider: 'relay-mcp-test'
		model:    executor.LogicExecutorModel.worker.str()
	}
}

fn (e CarrierTargetExecutor) warmup(mut app executor.AppFacade) ! {
	_ = e
	_ = app
}

fn (e CarrierTargetExecutor) close() {
	_ = e
}

fn (e CarrierTargetExecutor) dispatch_http(mut app executor.AppFacade, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
	_ = e
	_ = app
	_ = req
	return error('not_used')
}

fn (e CarrierTargetExecutor) open_websocket_session(mut app executor.AppFacade, req executor.WebSocketSessionOpenRequest) !executor.WebSocketSessionOpenOutcome {
	_ = e
	_ = app
	_ = req
	return error('not_used')
}

fn (e CarrierTargetExecutor) dispatch_stream(mut app executor.AppFacade, req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('not_used')
}

fn (e CarrierTargetExecutor) dispatch_mcp(mut app executor.AppFacade, req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	mut retained := e.app
	retained.websocket.state.mu.@lock()
	retained.websocket.state.conns['same'] = ws.HubConn{ id: 'same', lifecycle: e.replacement }
	retained.websocket.state.mu.unlock()

	_ = e
	_ = app
	return transport.WorkerMcpDispatchResponse{
		mode:             'mcp'
		event:            'message'
		id:               req.id
		handled:          true
		status:           200
		headers:          {
			'content-type': 'application/json'
		}
		body:             '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"${req.protocol_version}","capabilities":{},"serverInfo":{"name":"relay-test","version":"1.0.0"}}}'
		protocol_version: req.protocol_version
	}
}

fn (e CarrierTargetExecutor) dispatch_websocket_upstream(mut app executor.AppFacade, req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	_ = e
	_ = app
	_ = req
	return error('not_used')
}

fn (e CarrierTargetExecutor) dispatch_websocket_event(mut app executor.AppFacade, frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	_ = e
	_ = app
	_ = frame
	return error('not_used')
}

fn carrier_target_frame() relay.WireFrame {
	return relay.WireFrame{ kind: .data, id: 'frame', trace_id: 'trace', channel_id: 'channel', body: 'payload' }
}

fn carrier_target_install(mut app App, lifecycle &ws.DispatchConnState) {
	app.websocket.state.mu.@lock()
	defer { app.websocket.state.mu.unlock() }
	app.websocket.state.conns['same'] = ws.HubConn{ id: 'same', lifecycle: lifecycle }
}

fn test_old_relay_carrier_cannot_close_replacement() {
	mut app := &App{}
	old := &ws.DispatchConnState{ phase: .open }
	carrier_target_install(mut app, old)
	mut carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), 'same')
	replacement := &ws.DispatchConnState{ phase: .opening }
	carrier_target_install(mut app, replacement)
	app.websocket.state.pending['same'] = [ws.HubPendingMessage{ data: 'keep' }]
	carrier.close()
	assert replacement.phase() == .opening
	assert !replacement.socket_close_requested
	assert app.websocket.state.pending['same'][0].data == 'keep'
}

fn test_old_relay_carrier_cannot_observe_replacement_as_connected() {
	mut app := &App{}
	mut old := &ws.DispatchConnState{ phase: .open }
	carrier_target_install(mut app, old)
	carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), 'same')
	old.mark_closing()
	carrier_target_install(mut app, &ws.DispatchConnState{ phase: .open })
	assert !carrier.connected()
}

fn test_old_relay_carrier_cannot_enqueue_into_replacement() {
	mut app := &App{}
	carrier_target_install(mut app, &ws.DispatchConnState{ phase: .open })
	mut carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), 'same')
	carrier_target_install(mut app, &ws.DispatchConnState{ phase: .opening })
	app.websocket.state.pending['same'] = [ws.HubPendingMessage{ data: 'keep' }]
	assert !carrier.send(carrier_target_frame()).ok
	assert app.websocket.state.pending['same'].len == 1
	assert app.websocket.state.pending['same'][0].data == 'keep'
}

fn test_missing_relay_carrier_does_not_acquire_a_future_registration() {
	mut app := &App{}
	mut carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), 'same')
	carrier_target_install(mut app, &ws.DispatchConnState{ phase: .opening })
	assert !carrier.connected()
	assert !carrier.send(carrier_target_frame()).ok
	assert 'same' !in app.websocket.state.pending
}

fn test_detached_relay_carrier_preserves_future_open_queue() {
	mut app := &App{}
	old := &ws.DispatchConnState{ phase: .open }
	carrier_target_install(mut app, old)
	mut carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), 'same')
	app.websocket.state.cleanup_owned('same', old)
	assert ws.hub_send_to(mut app.websocket.state, 'same', 'future', 'text')
	assert !carrier.send(carrier_target_frame()).ok
	carrier.close()
	assert app.websocket.state.pending['same'].len == 1
	assert app.websocket.state.pending['same'][0].data == 'future'
}

fn test_stale_relay_channel_cancel_does_not_reach_replacement() {
	mut app := &App{}
	carrier_target_install(mut app, &ws.DispatchConnState{ phase: .open })
	mut carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), 'same')
	carrier_target_install(mut app, &ws.DispatchConnState{ phase: .opening })
	assert !carrier.close_channel('channel', 'trace').ok
	assert 'same' !in app.websocket.state.pending
}

fn test_current_relay_carrier_keeps_opening_queue_and_close_behavior() {
	mut app := &App{}
	lifecycle := &ws.DispatchConnState{ phase: .opening }
	carrier_target_install(mut app, lifecycle)
	mut carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), 'same')
	assert carrier.connected()
	assert carrier.send(carrier_target_frame()).ok
	assert app.websocket.state.pending['same'].len == 1
	carrier.close()
	assert lifecycle.phase() == .closing
	assert 'same' !in app.websocket.state.pending
}

fn test_relay_pipeline_captures_carrier_before_business_callback_replacement() {
	mut app := &App{}
	replacement := &ws.DispatchConnState{ phase: .opening }
	app.engines.primary.logic_executor = CarrierTargetExecutor{ app: app, replacement: replacement }
	app.plan = runtime_plan.RuntimePlan{
		relays:    {
			'edge': runtime_plan.RelayPlan{ id: 'edge' }
		}
		pipelines: [runtime_plan.PipelinePlan{ id: 'relay/mcp', ingress: runtime_plan.ResourceRef{ domain: .relay, id: 'edge' }, egress: runtime_plan.ResourceRef{ domain: .adapter, id: 'mcp' } }]
		adapters:  {
			'mcp': runtime_plan.AdapterPlan{ id: 'mcp', kind: 'mcp' }
		}
	}
	app.pipelines.relay = RelayPipelineRuntime.new(app.plan)
	carrier_target_install(mut app, &ws.DispatchConnState{ phase: .open })
	frame := relay.WireFrame{
		kind:       .open
		id:         'request'
		trace_id:   'trace'
		channel_id: 'session'
		body:       '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
		headers:    {
			'content-type':         'application/json'
			'mcp-protocol-version': '2025-06-18'
		}
		metadata:   {
			'http_method': 'POST'
			'path':        '/mcp'
		}
	}
	outcomes := app.dispatch_and_send_relay_ingress_frame('edge', 'same', frame, 0)
	assert outcomes.len == 1
	assert outcomes[0].action == 'response'
	assert outcomes[0].status == 200
	assert !outcomes[0].carrier_send_ok
	assert 'same' !in app.websocket.state.pending
	assert replacement.phase() == .opening
}

fn carrier_target_read(mut peer net.TcpConn, count int) []u8 {
	mut result := []u8{len: count}
	mut offset := 0
	for offset < count {
		mut buffer := []u8{len: count - offset}
		n := peer.read(mut buffer) or { panic(err) }
		assert n > 0
		copy(mut result[offset..], buffer[..n])
		offset += n
	}
	return result
}

fn test_current_relay_carrier_native_send_reaches_captured_socket() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(address.str()) or { panic(err) }
	mut server := listener.accept() or { panic(err) }
	defer {
		peer.close() or {}
		server.close() or {}
	}
	peer.set_read_timeout(time.second)
	mut client := websocket.new_client('ws://127.0.0.1:1') or { panic(err) }
	client.conn = server
	client.set_state(.open)
	mut app := &App{}
	lifecycle := &ws.DispatchConnState{ phase: .open }
	app.websocket.state.register_conn('same', '', 'GET', 'request', 'trace', '/', {}, {}, '', client, lifecycle)
	mut carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), 'same')
	assert carrier.send(carrier_target_frame()).ok
	header := carrier_target_read(mut peer, 2)
	assert header[0] == 0x81
	// Read extended payload length, then unmask the complete encoded Relay frame.
	mut length := int(header[1] & 0x7f)
	if length == 126 {
		extended := carrier_target_read(mut peer, 2)
		length = (int(extended[0]) << 8) | int(extended[1])
	}
	assert length < 65536
	mask := if header[1] & 0x80 != 0 { carrier_target_read(mut peer, 4) } else { []u8{} }
	mut payload := carrier_target_read(mut peer, length)
	if mask.len > 0 {
		for i in 0 .. payload.len { payload[i] ^= mask[i % 4] }
	}
	assert relay.decode_frame(payload.bytestr())!.body == 'payload'
	app.websocket.state.unregister_owned('same', lifecycle)
}

fn test_stale_relay_carrier_does_not_write_to_replacement_native_socket() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(address.str()) or { panic(err) }
	mut server := listener.accept() or { panic(err) }
	defer {
		peer.close() or {}
		server.close() or {}
	}
	peer.set_read_timeout(50 * time.millisecond)
	mut client := websocket.new_client('ws://127.0.0.1:1') or { panic(err) }
	client.conn = server
	client.set_state(.open)
	mut app := &App{}
	carrier_target_install(mut app, &ws.DispatchConnState{ phase: .open })
	mut carrier := ws.new_relay_carrier(app.websocket.build_relay_carrier_context(), 'same')
	replacement := &ws.DispatchConnState{ phase: .open }
	app.websocket.state.register_conn('same', '', 'GET', 'new', 'trace', '/', {}, {}, '', client, replacement)
	assert !carrier.send(carrier_target_frame()).ok
	mut buffer := []u8{len: 1}
	read := peer.read(mut buffer) or { 0 }
	assert read == 0
	assert replacement.phase() == .open
	app.websocket.state.unregister_owned('same', replacement)
}
