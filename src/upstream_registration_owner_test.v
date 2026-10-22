module main

import net
import net.http
import time
import upstream
import upstream.transport

fn upstream_registration_plan() transport.WorkerUpstreamPlanFrame {
	return transport.WorkerUpstreamPlanFrame{ name: 'provider', transport: 'http', codec: 'ndjson', mapper: 'ndjson_text_field', output_stream_type: 'text', fixture_path: '/vhttpd-nonexistent-registration-fixture' }
}

fn upstream_registration_add(mut registry UpstreamRuntimeRegistry, trace string) UpstreamRuntimeRegistration {
	return registry.register(upstream_registration_plan(), 'get', '/events?cursor=a', 'shared', trace) or { panic('missing registration') }
}

fn test_duplicate_request_ids_have_independent_upstream_registration_lifetimes() {
	mut registry := UpstreamRuntimeRegistry.new()
	first := upstream_registration_add(mut registry, 'first')
	second := upstream_registration_add(mut registry, 'second')
	assert first.key != second.key
	assert registry.active_count() == 2
	registry.unregister(first)
	registry.unregister(first)
	snapshot := registry.snapshot(true, 10, 0, '', '')
	assert snapshot.active_count == 1
	assert snapshot.sessions[0].request_id == 'shared'
	assert snapshot.sessions[0].id == 'shared'
	assert snapshot.sessions[0].trace_id == 'second'
	registry.unregister(second)
	assert registry.active_count() == 0
	plans, errors := registry.totals()
	assert plans == 2
	assert errors == 0
}

fn test_upstream_registration_cannot_remove_another_registry_record() {
	mut first := UpstreamRuntimeRegistry.new()
	mut second := UpstreamRuntimeRegistry.new()
	a := upstream_registration_add(mut first, 'first')
	b := upstream_registration_add(mut second, 'second')
	second.unregister(a)
	assert second.active_count() == 1
	first.unregister(b)
	assert first.active_count() == 1
	first.unregister(a)
	second.unregister(b)
	assert first.active_count() == 0
	assert second.active_count() == 0
}

fn upstream_registration_wait(ch chan bool) {
	select {
		_ := <-ch {
		}
		3 * time.second {
			panic('upstream registration fixture timeout')
		}
	}
}

fn upstream_registration_concurrent(mut registry UpstreamRuntimeRegistry, ready chan bool, release chan bool, done chan bool, trace string) {
	registration := upstream_registration_add(mut registry, trace)
	ready <- true
	_ := <-release
	registry.unregister(registration)
	registry.unregister(registration)
	done <- true
}

fn test_concurrent_upstream_requests_with_shared_id_remain_independent() {
	mut registry := &UpstreamRuntimeRegistry{}
	ready := chan bool{cap: 24}
	done := chan bool{cap: 24}
	release := chan bool{cap: 24}
	for i in 0 .. 24 {
		spawn upstream_registration_concurrent(mut registry, ready, release, done, i.str())
	}
	for _ in 0 .. 24 { upstream_registration_wait(ready) }
	assert registry.snapshot(true, 30, 0, '', '').returned_count == 24
	for expected in 0 .. 24 {
		release <- true
		upstream_registration_wait(done)
		assert registry.active_count() == 23 - expected
	}
	plans, _ := registry.totals()
	assert plans == 24
}

fn test_upstream_snapshot_preserves_duplicate_correlation_ids_and_detaches_rows() {
	mut registry := UpstreamRuntimeRegistry.new()
	first := upstream_registration_add(mut registry, 'first')
	second := upstream_registration_add(mut registry, 'second')
	for key, session in registry.sessions {
		registry.sessions[key] = upstream.UpstreamRuntimeSession{ ...session, started_at_unix: 123 }
	}
	retained := registry.snapshot(true, 10, 0, 'external_upstream', 'provider')
	assert retained.active_count == 2
	assert retained.returned_count == 2
	assert retained.sessions[0].trace_id != retained.sessions[1].trace_id
	assert registry.snapshot(true, 10, 0, 'missing', '').active_count == 0
	registry.unregister(first)
	registry.unregister(second)
	assert retained.sessions.len == 2
	assert retained.active_count == 2
	assert registry.snapshot(false, 10, 0, '', '').active_count == 0
}

fn upstream_registration_max_int() int {
	return int((u64(1) << (sizeof(int) * 8 - 1)) - 1)
}

fn test_upstream_snapshot_pagination_rejects_negative_ranges_and_overflow() {
	mut registry := UpstreamRuntimeRegistry.new()
	for i in 0 .. 3 { _ := upstream_registration_add(mut registry, i.str()) }
	assert registry.snapshot(true, -1, -1, '', '').returned_count == 0
	all := registry.snapshot(true, upstream_registration_max_int(), -1, '', '')
	assert all.returned_count == 3
	assert all.offset == 0
	assert registry.snapshot(true, upstream_registration_max_int(), 1, '', '').returned_count == 2
	assert registry.snapshot(true, upstream_registration_max_int(), upstream_registration_max_int(), '', '').returned_count == 0
	brief := registry.snapshot(false, upstream_registration_max_int(), 1, '', '')
	assert brief.active_count == 3
	assert brief.returned_count == 0
	assert brief.sessions.len == 0
}

fn test_empty_upstream_request_id_has_explicit_absent_registration() {
	mut registry := UpstreamRuntimeRegistry.new()
	assert registry.register(upstream_registration_plan(), 'get', '/', '', 'trace') == none
	assert registry.active_count() == 0
	plans, errors := registry.totals()
	assert plans == 0
	assert errors == 0
}

fn upstream_registration_tcp_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	peer.set_read_timeout(time.second)
	return listener.accept() or { panic(err) }, peer
}

fn upstream_registration_execute(rt UpstreamRuntimeContext, server &net.TcpConn, trace string, done chan bool) {
	mut ctx := Context{ req: http.Request{ method: .get, url: '/events' }, conn: server }
	UpstreamRuntimeContext.execute_plan(rt, mut ctx, upstream_registration_plan(), 'GET', '/events', 'shared', trace, time.now().unix_milli())
	done <- true
}

fn test_upstream_execution_errors_release_only_their_own_registration() {
	mut app := &App{}
	base := app.build_upstream_runtime_context()
	mut servers := []&net.TcpConn{}
	mut peers := []&net.TcpConn{}
	mut releases := []chan bool{}
	mut dones := []chan bool{}
	ready := chan bool{cap: 2}
	for _ in 0 .. 2 {
		server, peer := upstream_registration_tcp_pair()
		servers << server
		peers << peer
		releases << chan bool{cap: 1}
		dones << chan bool{cap: 1}
	}
	defer {
		for mut peer in peers { peer.close() or {} }
	}
	for i in 0 .. 2 {
		release := releases[i]
		rt := UpstreamRuntimeContext{
			...base
			register_fn: fn [base, ready, release] (plan transport.WorkerUpstreamPlanFrame, method string, path string, id string, trace string) ?UpstreamRuntimeRegistration {
				registration := base.register(plan, method, path, id, trace) or { return none }
				ready <- true
				_ := <-release
				return registration
			}
		}
		spawn upstream_registration_execute(rt, servers[i], i.str(), dones[i])
	}
	upstream_registration_wait(ready)
	upstream_registration_wait(ready)
	assert app.upstreams.active_count() == 2
	releases[0] <- true
	upstream_registration_wait(dones[0])
	assert app.upstreams.snapshot(true, 10, 0, '', '').sessions[0].trace_id == '1'
	releases[1] <- true
	upstream_registration_wait(dones[1])
	assert app.upstreams.active_count() == 0
	plans, errors := app.upstreams.totals()
	assert plans == 2
	assert errors == 2
	for mut peer in peers {
		mut bytes := []u8{len: 4096}
		n := peer.read(mut bytes) or { panic(err) }
		assert bytes[..n].bytestr().contains('502 Bad Gateway')
	}
}
