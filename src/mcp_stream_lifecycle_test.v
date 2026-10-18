module main

import net
import executor
import time
import server_lifecycle
import runtime_plan

struct McpHttpPair {
	server &net.TcpConn @[required]
	peer   &net.TcpConn @[required]
}

fn mcp_http_pair() McpHttpPair {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	server := listener.accept() or { panic(err) }
	peer.set_read_timeout(time.second)
	return McpHttpPair{ server: server, peer: peer }
}

fn open_mcp_http_stream(mut app App, pair McpHttpPair) {
	mut ctx := Context{}
	ctx.conn = pair.server
	ctx.req.url = '/mcp'
	ctx.req.method = .get
	ctx.query['session_id'] = 'session'
	mcp_handle_get_http(mut app, mut ctx)
}

fn mcp_http_read(mut peer net.TcpConn, marker string) string {
	mut text := ''
	mut bytes := []u8{len: 4096}
	for !text.contains(marker) {
		n := peer.read(mut bytes) or { panic(err) }
		assert n > 0
		text += bytes[..n].bytestr()
	}
	return text
}

fn test_mcp_http_handoff_replacement_and_process_shutdown_release_all_streams() {
	mut app := &App{}
	app.engines.primary.logic_executor = executor.DisabledLogicExecutor{}
	app.protocols.mcp.ensure_session('session', '2025-06-18', '', '', '')
	first := mcp_http_pair()
	second := mcp_http_pair()
	defer {
		mut p := first.peer
		p.close() or {}
		mut q := second.peer
		q.close() or {}
	}
	open_mcp_http_stream(mut app, first)
	mut first_peer := first.peer
	initial := mcp_http_read(mut first_peer, ': connected\n\n')
	assert initial.starts_with('HTTP/1.1 200 OK\r\n')
	assert initial.contains('Content-Type: text/event-stream\r\n')
	assert initial.contains('mcp-session-id: session\r\n')
	open_mcp_http_stream(mut app, second)
	mut second_peer := second.peer
	assert mcp_http_read(mut second_peer, ': connected\n\n').contains('HTTP/1.1 200 OK')
	assert app.protocols.mcp.do_queue('session', '{"message":"replacement"}').queued
	assert mcp_http_read(mut second_peer, 'data: {"message":"replacement"}\n\n') == 'event: message\ndata: {"message":"replacement"}\n\n'
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		shutdown_app_runtime(mut app, server_lifecycle.ServerRuntimeConfig{
			executor_plan: executor.LogicExecutorRuntimePlan{
				executor:  executor.DisabledLogicExecutor{}
				lifecycle: executor.disabled_executor_lifecycle()
			}
		})
		done <- true
	}()
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('process shutdown did not join MCP streams')
		}
	}
	assert app.protocols.mcp.active_streams() == 0
	assert app.protocols.mcp.sessions['session'].stream == none
	mut bytes := []u8{len: 1}
	n := second_peer.read(mut bytes) or {
		assert err.code() != net.err_timed_out_code
		0
	}
	assert n == 0
}

fn test_mcp_http_handoff_after_stop_closes_taken_over_socket() {
	mut app := &App{}
	app.protocols.mcp.ensure_session('session', '', '', '', '')
	app.protocols.mcp.request_stop()
	pair := mcp_http_pair()
	defer {
		mut p := pair.peer
		p.close() or {}
	}
	open_mcp_http_stream(mut app, pair)
	assert app.protocols.mcp.active_streams() == 0
	mut peer := pair.peer
	mut bytes := []u8{len: 1}
	n := peer.read(mut bytes) or {
		assert err.code() != net.err_timed_out_code
		0
	}
	assert n == 0
}

fn test_mcp_http_stream_survives_plan_projection_and_joins_shutdown() {
	mut app := &App{}
	app.engines.primary.logic_executor = executor.DisabledLogicExecutor{}
	app.protocols.mcp.ensure_session('session', '', '', '', '')
	pair := mcp_http_pair()
	defer {
		mut peer := pair.peer
		peer.close() or {}
	}
	open_mcp_http_stream(mut app, pair)
	mut peer := pair.peer
	assert mcp_http_read(mut peer, ': connected\n\n').contains('HTTP/1.1 200 OK')
	projection := RuntimePlanRuntimeProjection.from_plan(runtime_plan.RuntimePlan{}, 'web', [], '', '', map[string]string{}, app.engines.additional.clone(), app.provider_runtime_settings_snapshot())
	app.mu.@lock()
	retirement := app.apply_runtime_plan_runtime_projection(runtime_plan.RuntimePlan{}, projection)
	app.mu.unlock()
	app.protocols.plugins.finish_retirement(retirement)
	assert app.protocols.mcp.active_streams() == 1
	assert app.protocols.mcp.do_queue('session', '{"after_reload":true}').queued
	assert mcp_http_read(mut peer, 'data: {"after_reload":true}\n\n').contains('after_reload')
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		shutdown_app_runtime(mut app, server_lifecycle.ServerRuntimeConfig{
			executor_plan: executor.LogicExecutorRuntimePlan{ executor: executor.DisabledLogicExecutor{}, lifecycle: executor.disabled_executor_lifecycle() }
		})
		done <- true
	}()
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('reloaded MCP owner did not finish shutdown')
		}
	}
	assert app.protocols.mcp.active_streams() == 0
	mut bytes := []u8{len: 1}
	n := peer.read(mut bytes) or {
		assert err.code() != net.err_timed_out_code
		0
	}
	assert n == 0
}
