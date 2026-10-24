module main

import connection_runtime
import io
import net
import net.http
import net.websocket
import relay
import runtime_plan
import time
import ws

@[heap]
struct OwnedRelayProbe {
	url           string
	block_prepare bool
	block_payload bool
	attempted     chan bool = chan bool{cap: 8}
	backoff       chan bool = chan bool{cap: 8}
	attached      chan bool = chan bool{cap: 8}
	detached      chan bool = chan bool{cap: 8}
	payload       chan bool = chan bool{cap: 8}
	release       chan bool = chan bool{cap: 1}
}

fn owned_relay_await(ch chan bool) {
	select {
		value := <-ch {
			assert value
		}
		3 * time.second {
			panic('relay lifecycle deadline')
		}
	}
}

fn owned_relay_context(probe &OwnedRelayProbe) ws.RelayAgentRuntimeContext {
	return ws.RelayAgentRuntimeContext{
		prepare_attempt_fn: fn [probe] (_ relay.RelayDescriptor, _ string, _ i64) ws.RelayAgentConnectAttempt {
			probe.attempted <- true
			if probe.block_prepare { _ := <-probe.release }
			return ws.RelayAgentConnectAttempt{ ok: probe.url != '', url: probe.url, hello_payload: '{}' }
		}
		handle_payload_fn:  fn [probe] (_ string, _ string, _ string, _ i64, _ int) ws.RelayAgentPayloadOutcome {
			probe.payload <- true
			if probe.block_payload { _ := <-probe.release }
			return ws.RelayAgentPayloadOutcome{}
		}
		disconnected_fn:    fn (_ relay.RelayDescriptor, _ string, _ i64) {}
		reconnect_delay_fn: fn [probe] (_ relay.RelayDescriptor, _ string, _ i64) int {
			probe.backoff <- true
			return int(time.hour / time.millisecond)
		}
		attach_carrier_fn:  fn [probe] (_ relay.RelayDescriptor, _ string, _ string) {
			probe.attached <- true
		}
		detach_carrier_fn:  fn [probe] (_ relay.RelayDescriptor, _ string, _ string) {
			probe.detached <- true
		}
	}
}

fn owned_relay_start(mut app App, probe &OwnedRelayProbe) &connection_runtime.Run {
	descriptor := relay.RelayDescriptor{ id: 'edge', mode: .agent }
	mut run := app.websocket.upstream_runs.reserve(relay_agent_run_key(descriptor.id)) or { panic('reservation') }
	ctx := owned_relay_context(probe)
	websocket_rt := app.websocket.build_relay_session_context()
	mut registry := &app.websocket.upstream_runs
	spawn RelayAgentRuntime.run_loop(ctx, websocket_rt, descriptor, 'test', mut registry, mut run)
	return run
}

fn test_relay_agent_shutdown_before_spawn_skips_attempt_and_rejects_late_start() {
	mut app := &App{}
	probe := &OwnedRelayProbe{}
	mut run := app.websocket.upstream_runs.reserve(relay_agent_run_key('edge')) or { panic('reserve') }
	stop := app.request_background_network_stop()
	RelayAgentRuntime.run_loop(owned_relay_context(probe), app.websocket.build_relay_session_context(),
		relay.RelayDescriptor{ id: 'edge', mode: .agent }, '', mut app.websocket.upstream_runs, mut run)
	stop.wait()
	assert run.finished()
	assert app.websocket.upstream_runs.reserve(relay_agent_run_key('edge')) == none
	select {
		_ := <-probe.attempted {
			panic('late attempt')
		}
		else {
		}
	}
}

fn test_relay_agent_stop_cancels_hour_backoff_and_releases_registry() {
	mut app := &App{}
	probe := &OwnedRelayProbe{}
	mut run := owned_relay_start(mut app, probe)
	owned_relay_await(probe.backoff)
	assert app.websocket.upstream_runs.reserve(relay_agent_run_key('edge')) == none
	start := time.now()
	app.websocket.upstream_runs.stop_prefix('relay-agent/')
	assert time.now() - start < time.second
	assert run.finished()
	mut replacement := app.websocket.upstream_runs.reserve(relay_agent_run_key('edge')) or { panic('not released') }
	app.websocket.upstream_runs.release(relay_agent_run_key('edge'), mut replacement)
}

fn test_relay_agent_shutdown_waits_for_claimed_prepare_without_late_connect() {
	mut app := &App{}
	probe := &OwnedRelayProbe{ url: 'ws://127.0.0.1:1/', block_prepare: true }
	mut run := owned_relay_start(mut app, probe)
	owned_relay_await(probe.attempted)
	stop := app.request_background_network_stop()
	assert run.stopped() && !run.finished()
	probe.release <- true
	stop.wait()
	assert run.finished()
	select {
		_ := <-probe.attached {
			panic('late attachment')
		}
		else {
		}
	}
	select {
		_ := <-probe.backoff {
			panic('late retry callback')
		}
		else {
		}
	}
}

@[heap]
struct OwnedRelayServer {
	incoming bool
	hello    chan bool = chan bool{cap: 1}
	done     chan bool = chan bool{cap: 1}
}

fn owned_relay_server_message(mut client websocket.Client, msg &websocket.Message, ref voidptr) ! {
	state := unsafe { &OwnedRelayServer(ref) }
	if msg.opcode != .text_frame { return }
	assert msg.payload.bytestr() == '{}'
	state.hello <- true
	if state.incoming { client.write_string('incoming')! }
}

fn owned_relay_serve(mut listener net.TcpListener, state &OwnedRelayServer) {
	mut conn := listener.accept() or { panic(err) }
	defer {
		conn.close() or {}
		state.done <- true
	}
	conn.set_read_timeout(3 * time.second)
	mut reader := io.new_buffered_reader(reader: conn)
	req := http.parse_request(mut reader) or { panic(err) }
	key := req.header.get(.sec_websocket_key) or { panic('missing websocket key') }
	mut server := websocket.new_server(.ip, 0, '')
	server.on_message_ref(owned_relay_server_message, state)
	server.handle_handshake(mut conn, key) or {}
}

fn test_relay_agent_shutdown_interrupts_live_reader_and_cleans_hub_before_release() {
	mut app := &App{}
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	server := &OwnedRelayServer{}
	spawn owned_relay_serve(mut listener, server)
	probe := &OwnedRelayProbe{ url: 'ws://${addr}/relay' }
	mut run := owned_relay_start(mut app, probe)
	owned_relay_await(probe.attached)
	owned_relay_await(server.hello)
	assert app.websocket.state.conn_open('agent:edge')
	start := time.now()
	stop := app.request_background_network_stop()
	stop.wait()
	assert time.now() - start < time.second
	owned_relay_await(probe.detached)
	owned_relay_await(server.done)
	assert run.finished()
	assert !app.websocket.state.conn_open('agent:edge')
	assert app.websocket.state.conns.len == 0
	stop.wait()
}

fn test_relay_agent_shutdown_joins_claimed_payload_before_removing_carrier() {
	mut app := &App{}
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	server := &OwnedRelayServer{ incoming: true }
	spawn owned_relay_serve(mut listener, server)
	probe := &OwnedRelayProbe{ url: 'ws://${addr}/relay', block_payload: true }
	mut run := owned_relay_start(mut app, probe)
	owned_relay_await(probe.payload)
	stop := app.request_background_network_stop()
	assert run.stopped() && !run.finished()
	select {
		_ := <-probe.detached {
			panic('cleanup overtook claimed dispatch')
		}
		else {
		}
	}
	probe.release <- true
	stop.wait()
	owned_relay_await(probe.detached)
	owned_relay_await(server.done)
	assert run.finished()
	assert app.websocket.state.conns.len == 0
}

fn test_relay_agent_repeated_concurrent_autostart_reserves_one_run() {
	mut app := &App{}
	app.relay = relay.new_runtime(runtime_plan.RuntimePlan{
		relays: {
			'edge': runtime_plan.RelayPlan{
				id:      'edge'
				mode:    'agent'
				carrier: 'websocket'
				options: runtime_plan.PlanOptions{
					strings: {
						'url':     'ws://127.0.0.1:1/'
						'node_id': 'test'
					}
					ints:    {
						'reconnect_delay_ms': 3600000
					}
					bools:   {
						'autostart': true
					}
				}
			}
		}
	}) or { panic(err) }
	mut calls := []thread int{}
	for _ in 0 .. 8 { calls << spawn app.start_relay_agents_once('test') }
	mut total := 0
	for call in calls { total += call.wait() }
	assert total == 1
	stop := app.request_background_network_stop()
	stop.wait()
	assert app.start_relay_agents_once('late') == 0
}

fn owned_relay_stop_during_wire_handshake(tls bool) {
 mut app := &App{}
 mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
 defer { listener.close() or {} }
 listener.set_accept_timeout(time.second)
 address := listener.addr() or { panic(err) }
 scheme := if tls { 'wss' } else { 'ws' }
 probe := &OwnedRelayProbe{url:'${scheme}://${address}/stalled'}
 mut run := owned_relay_start(mut app, probe)
 mut peer := listener.accept() or { panic(err) }
 peer.set_read_timeout(time.second)
 mut first := []u8{len:1024}
 assert peer.read(mut first) or { 0 } > 0
 stop := app.request_background_network_stop()
 finished := chan bool{cap:1}
 spawn fn [stop, finished] () { stop.wait(); finished <- true }()
 mut stopped := false
 select { _ := <-finished { stopped = true } 500 * time.millisecond {} }
 peer.close() or {}
 if !stopped { owned_relay_await(finished) }
 assert stopped, 'relay stop waited for a stalled wire handshake'
 assert run.finished()
 assert app.websocket.state.conns.len == 0
 select { _ := <-probe.attached { panic('handshake cancellation published carrier') } else {} }
}

fn test_relay_agent_stop_interrupts_stalled_http_upgrade_before_carrier_publication() {
 owned_relay_stop_during_wire_handshake(false)
}

fn test_relay_agent_stop_interrupts_stalled_tls_handshake_before_carrier_publication() {
 owned_relay_stop_during_wire_handshake(true)
}
