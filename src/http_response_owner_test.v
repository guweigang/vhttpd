module main

import api.openai
import config
import executor
import server_lifecycle
import io
import net
import net.http
import time

#include <fcntl.h>

fn C.fcntl(int, int, ...voidptr) int

struct ResponseOwnerPair {
	server &net.TcpConn @[required]
	peer   &net.TcpConn @[required]
}

fn response_owner_pair() ResponseOwnerPair {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(address.str()) or { panic(err) }
	peer.set_read_timeout(time.second)
	return ResponseOwnerPair{ server: listener.accept() or { panic(err) }, peer: peer }
}

fn response_owner_read_closed(mut peer net.TcpConn) string {
	mut body := ''
	mut buffer := []u8{len: 4096}
	for {
		n := peer.read(mut buffer) or {
			assert err is io.Eof, 'connection did not close: ${err}'
			break
		}
		if n == 0 { break }
		body += buffer[..n].bytestr()
	}
	return body
}

fn test_builtin_sse_first_write_failure_releases_taken_over_socket() {
	pair := response_owner_pair()
	mut server := pair.server
	mut peer := pair.peer
	defer { peer.close() or {} }
	defer { server.close() or {} }
	fd := server.sock.handle
	assert net.shutdown(fd, how: .write) == 0
	mut ctx := Context{}
	ctx.conn = server
	ctx.query = {
		'count':       '1'
		'interval_ms': '0'
	}
	mut app := &App{}
	app.events_stream(mut ctx)
	assert C.fcntl(fd, C.F_GETFD, 0) == -1, 'manual SSE owner leaked on its first failed write'
}

fn test_builtin_sse_success_sends_close_event_and_releases_socket() {
	pair := response_owner_pair()
	mut peer := pair.peer
	defer { peer.close() or {} }
	fd := pair.server.sock.handle
	mut ctx := Context{}
	ctx.conn = pair.server
	ctx.query = {
		'count':       '2'
		'interval_ms': '0'
	}
	mut app := &App{}
	app.events_stream(mut ctx)
	assert C.fcntl(fd, C.F_GETFD, 0) == -1
	body := response_owner_read_closed(mut peer)
	assert body.count('event: ping\n') == 2
	assert body.count('event: close\n') == 1
}

fn test_builtin_sse_later_write_failure_releases_socket() {
	pair := response_owner_pair()
	mut peer := pair.peer
	defer { peer.close() or {} }
	fd := pair.server.sock.handle
	done := chan bool{cap: 1}
	spawn fn [pair, done] () {
		mut ctx := Context{}
		ctx.conn = pair.server
		ctx.query = {
			'count':       '20'
			'interval_ms': '100'
		}
		mut app := &App{}
		app.events_stream(mut ctx)
		done <- true
	}()
	// Seeing the retry frame proves the first write succeeded. Interrupt the
	// writer while later events remain, exercising the loop's early return.
	mut received := ''
	mut buffer := []u8{len: 4096}
	for !received.contains('retry: 1000\n\n') {
		n := peer.read(mut buffer) or { panic(err) }
		assert n > 0
		received += buffer[..n].bytestr()
	}
	assert net.shutdown(fd, how: .write) == 0
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('SSE writer did not return after failure')
		}
	}
	assert C.fcntl(fd, C.F_GETFD, 0) == -1, 'manual SSE owner leaked after a later failed write'
}

fn response_owner_openai_failure(kind string) {
	pair := response_owner_pair()
	mut server := pair.server
	mut peer := pair.peer
	defer { peer.close() or {} }
	defer { server.close() or {} }
	fd := server.sock.handle
	mut ctx := Context{}
	ctx.conn = server
	ctx.req.version = .v1_1
	ctx.req.header = http.new_header_from_map({
		http.CommonHeader.connection: 'keep-alive'
	})
	mut app := &App{}
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	address := listener.addr() or { panic(err) }
	listener.close() or { panic(err) }
	plan := openai.OpenAIResolvedPlan{
		backend_name:    'failure-probe'
		backend:         config.OpenAIBackendConfig{ base_url: 'http://${address}', kind: 'openai_http' }
		response_codec:  'ndjson'
		output_protocol: 'openai.chat.completion'
		path:            '/chat'
	}
	match kind {
		'passthrough' {
			OpenAIProxyRuntime.stream(mut app, mut ctx, plan, 'POST', '/chat', 'owner', 'trace', 0)
		}
		'mapped' {
			OpenAIProxyRuntime.mapped_stream(mut app, mut ctx, plan, 'POST', '/chat', 'owner', 'trace', 0)
		}
		'executor' {
			OpenAIProxyRuntime.executor_stream(mut app, mut ctx, plan, 'POST', '/chat', 'owner', 'trace', 0)
		}
		'responses' {
			OpenAIProxyRuntime.responses_executor_stream(mut app, mut ctx, plan, 'POST', '/responses', 'owner', 'trace', 0)
		}
		else { panic(kind) }
	}
	// Reusable takeover borrows the descriptor. veb must see it still live,
	// together with explicit close intent, after the handler returns.
	assert C.fcntl(fd, C.F_GETFD, 0) >= 0, '${kind} closed a descriptor still owned by veb'
	assert ctx.res.header.get(.connection) or { '' } == 'close'
}

fn test_openai_passthrough_failure_leaves_close_with_framework() {
	response_owner_openai_failure('passthrough')
}

fn test_openai_mapped_failure_leaves_close_with_framework() {
	response_owner_openai_failure('mapped')
}

fn test_openai_executor_failure_leaves_close_with_framework() {
	response_owner_openai_failure('executor')
}

fn test_openai_responses_failure_leaves_close_with_framework() {
	response_owner_openai_failure('responses')
}

fn test_openai_failure_framework_closes_connection_and_keeps_listener_alive() {
	mut reserved := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	address := reserved.addr() or { panic(err) }
	port := address.port() or { panic(err) }
	reserved.close() or { panic(err) }
	mut app := &App{}
	app.use(
		handler: fn [mut app] (mut ctx Context) bool {
			if ctx.req.url != '/owned-stream-error' { return true }
			OpenAIProxyRuntime.executor_stream(mut app, mut ctx, openai.OpenAIResolvedPlan{},
				'GET', '/owned-stream-error', 'owner', 'trace', 0)
			return false
		}
	)
	cfg := server_lifecycle.ServerRuntimeConfig{
		host:             '127.0.0.1'
		port:             int(port)
		serve_data_plane: true
		executor_plan:    executor.LogicExecutorRuntimePlan{
			executor:  executor.DisabledLogicExecutor{}
			lifecycle: executor.disabled_executor_lifecycle()
		}
	}
	spawn serve_server_runtime(mut app, cfg)
	defer {
		stop := app.request_http_ingress_stop()
		stop.wait() or { panic(err) }
	}
	deadline := time.now().add(3 * time.second)
	for {
		http.get('http://${address}/health') or {
			assert time.now() < deadline
			time.sleep(time.millisecond)
			continue
		}
		break
	}
	mut peer := net.dial_tcp(address.str()) or { panic(err) }
	defer { peer.close() or {} }
	peer.set_read_timeout(time.second)
	peer.write_string('GET /owned-stream-error HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n') or { panic(err) }
	body := response_owner_read_closed(mut peer)
	assert body.contains('openai_executor_failed')
	assert body.ends_with('0\r\n\r\n')
	response := http.get('http://${address}/health') or { panic(err) }
	assert response.status_code == 200
}
