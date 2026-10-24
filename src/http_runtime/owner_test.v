module http_runtime

import net
import net.http
import time
import veb

struct HttpTestContext {
	veb.Context
}

@[heap]
struct HttpTestApp {
	veb.Middleware[HttpTestContext]
	owner         &Owner @[required]
	pause_publish bool
	published     chan bool = chan bool{cap: 1}
	resume        chan bool = chan bool{cap: 1}
	ready         chan bool = chan bool{cap: 1}
	entered       chan bool = chan bool{cap: 1}
	release       chan bool = chan bool{cap: 1}
	done          chan bool = chan bool{cap: 1}
}

fn (mut app HttpTestApp) init_server(server &veb.Server) {
	app.owner.publish(server)
	app.published <- true
	if app.pause_publish { _ := <-app.resume }
}

fn (mut app HttpTestApp) before_accept_loop() {
	app.owner.ready()
	app.ready <- true
}

@['/hold']
fn (mut app HttpTestApp) hold(mut ctx HttpTestContext) veb.Result {
	app.entered <- true
	_ := <-app.release
	return ctx.text('finished')
}

fn (mut _ HttpTestApp) index(mut ctx HttpTestContext) veb.Result { return ctx.text('ready') }

fn http_test_wait(ch chan bool) {
	select {
		value := <-ch {
			assert value
		}
		3 * time.second {
			panic('HTTP owner deadline')
		}
	}
}

fn http_test_port() int {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := (listener.addr() or { panic(err) }).port() or { panic(err) }
	listener.close() or { panic(err) }
	return int(port)
}

fn http_test_serve(mut app HttpTestApp, port int, mut run Run) {
	mut owner := app.owner
	app.use(
		handler: fn [mut owner] (mut ctx HttpTestContext) bool {
			if owner.accepting() { return true }
			ctx.res.set_status(.service_unavailable)
			ctx.text('stopping')
			return false
		}
	)
	owner.serve(mut run, fn [mut app, port] () {
		veb.run_at[HttpTestApp, HttpTestContext](mut app,
			host:                 '127.0.0.1'
			port:                 port
			family:               .ip
			show_startup_message: false
		) or { panic(err) }
	})
	app.done <- true
}

fn http_test_get(port int, result chan string) {
	response := http.get('http://127.0.0.1:${port}/hold') or { panic(err) }
	assert response.status_code == 200
	result <- response.body
}

fn http_test_response(result chan string) {
	select {
		body := <-result {
			assert body == 'finished'
		}
		3 * time.second {
			panic('missing drained response')
		}
	}
}

fn test_terminal_stop_before_start_rejects_reservation() {
	mut owner := &Owner{}
	owner.request_stop()
	owner.wait_stopped() or { panic(err) }
	assert owner.reserve('test') == none
	assert !owner.accepting()
}

fn test_stop_after_reservation_before_spawn_skips_server_creation() {
	mut owner := &Owner{}
	mut run := owner.reserve('test') or { panic('reserve') }
	assert owner.reserve('test') == none
	owner.request_stop()
	owner.serve(mut run, fn () { panic('late server creation') })
	owner.wait_stopped() or { panic(err) }
	assert owner.reserve('test') == none
}

fn test_shutdown_drains_handler_response_before_releasing_listener() {
	mut app := &HttpTestApp{ owner: &Owner{} }
	port := http_test_port()
	mut run := app.owner.reserve('test') or { panic('reserve') }
	spawn http_test_serve(mut app, port, mut run)
	http_test_wait(app.ready)
	result := chan string{cap: 1}
	spawn http_test_get(port, result)
	http_test_wait(app.entered)
	start := time.now()
	app.owner.request_stop()
	assert time.now() - start < time.second
	select {
		_ := <-app.done {
			panic('serve ended before handler')
		}
		else {
		}
	}
	assert !app.owner.accepting()
	app.release <- true
	http_test_response(result)
	http_test_wait(app.done)
	app.owner.wait_stopped() or { panic(err) }
	mut rebound := net.listen_tcp(.ip, '127.0.0.1:${port}') or { panic(err) }
	rebound.close() or { panic(err) }
	assert app.owner.reserve('test') == none
}

fn test_stop_during_native_publication_is_not_reset_by_server_startup() {
	mut app := &HttpTestApp{ owner: &Owner{}, pause_publish: true }
	port := http_test_port()
	mut run := app.owner.reserve('test') or { panic('reserve') }
	spawn http_test_serve(mut app, port, mut run)
	http_test_wait(app.published)
	app.owner.request_stop()
	app.resume <- true
	http_test_wait(app.done)
	app.owner.wait_stopped() or { panic(err) }
	assert app.owner.reserve('test') == none
}

fn test_shutdown_closes_idle_partial_header_without_waiting_for_read_timeout() {
	mut app := &HttpTestApp{ owner: &Owner{} }
	port := http_test_port()
	mut run := app.owner.reserve('test') or { panic('reserve') }
	spawn http_test_serve(mut app, port, mut run)
	http_test_wait(app.ready)
	mut peer := net.dial_tcp('127.0.0.1:${port}') or { panic(err) }
	defer { peer.close() or {} }
	peer.set_read_timeout(time.second)
	peer.write_string('GET / HTTP/1.1\r\n') or { panic(err) }
	app.owner.request_stop()
	http_test_wait(app.done)
	app.owner.wait_stopped() or { panic(err) }
	mut bytes := []u8{len: 1}
	assert (peer.read(mut bytes) or {
		assert err.code() != net.err_timed_out_code
		0
	}) == 0
}

fn test_concurrent_shutdown_callers_wait_for_the_same_response_drain() {
	mut app := &HttpTestApp{ owner: &Owner{} }
	port := http_test_port()
	mut run := app.owner.reserve('test') or { panic('reserve') }
	spawn http_test_serve(mut app, port, mut run)
	http_test_wait(app.ready)
	result := chan string{cap: 1}
	spawn http_test_get(port, result)
	http_test_wait(app.entered)
	joined := chan bool{cap: 4}
	mut owner := app.owner
	for _ in 0 .. 4 {
		spawn fn [mut owner, joined] () {
			owner.request_stop()
			owner.wait_stopped() or { panic(err) }
			joined <- true
		}()
	}
	deadline := time.now().add(time.second)
	for owner.accepting() {
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	select {
		_ := <-joined {
			panic('shutdown overtook response')
		}
		else {
		}
	}
	app.release <- true
	http_test_response(result)
	for _ in 0 .. 4 { http_test_wait(joined) }
	http_test_wait(app.done)
}

fn test_unsupported_native_lifecycle_is_reported_instead_of_silently_drained() {
	mut owner := &Owner{}
	mut run := owner.reserve('test') or { panic('reserve') }
	owner.serve(mut run, fn [mut owner] () {
		owner.publish(&veb.Server{})
		owner.ready()
		owner.request_stop()
		mut rejected := false
		owner.wait_stopped() or {
			assert err.msg().contains('not available with SSL')
			rejected = true
		}
		assert rejected
	})
}
