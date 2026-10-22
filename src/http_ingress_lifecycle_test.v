module main

import executor
import net
import net.http
import server_lifecycle
import time
import veb

fn managed_http_config(port int) server_lifecycle.ServerRuntimeConfig {
	return server_lifecycle.ServerRuntimeConfig{
		host:             '127.0.0.1'
		port:             port
		serve_data_plane: true
		executor_plan:    executor.LogicExecutorRuntimePlan{
			executor:  executor.DisabledLogicExecutor{}
			lifecycle: executor.disabled_executor_lifecycle()
		}
	}
}

fn managed_http_port() int {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := (listener.addr() or { panic(err) }).port() or { panic(err) }
	listener.close() or { panic(err) }
	return int(port)
}

fn managed_http_ready(port int) {
	deadline := time.now().add(3 * time.second)
	for {
		response := http.get('http://127.0.0.1:${port}/health') or {
			assert time.now() < deadline
			time.sleep(time.millisecond)
			continue
		}
		assert response.status_code == 200
		return
	}
}

fn managed_http_done(done chan bool) {
	select {
		value := <-done {
			assert value
		}
		3 * time.second {
			panic('managed HTTP shutdown deadline')
		}
	}
}

fn managed_http_wait(stop HttpIngressStop) {
	done := chan bool{cap: 1}
	spawn fn [stop, done] () {
		stop.wait() or { panic(err) }
		done <- true
	}()
	managed_http_done(done)
}

fn test_managed_data_and_admin_http_share_terminal_shutdown_and_release_ports() {
	mut app := &App{}
	data_port := managed_http_port()
	admin_port := managed_http_port()
	spawn serve_server_runtime(mut app, managed_http_config(data_port))
	assert AdminPlaneRuntime.start(mut app, '127.0.0.1', admin_port, '')
	assert !AdminPlaneRuntime.start(mut app, '127.0.0.1', admin_port, '')
	managed_http_ready(data_port)
	managed_http_ready(admin_port)
	stop := app.request_http_ingress_stop()
	managed_http_wait(stop)
	managed_http_wait(stop)
	assert !AdminPlaneRuntime.start(mut app, '127.0.0.1', admin_port, '')
	serve_server_runtime(mut app, managed_http_config(data_port))
	for port in [data_port, admin_port] {
		mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { panic(err) }
		listener.close() or { panic(err) }
	}
}

fn test_all_http_ingresses_are_notified_and_requests_drain_before_background_stop() {
	mut one := &App{}
	mut two := &App{}
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	one.use(
		handler: fn [entered, release] (mut ctx Context) bool {
			if ctx.req.url != '/hold' { return true }
			entered <- true
			_ := <-release
			ctx.text('finished')
			return false
		}
	)
	first := managed_http_port()
	second := managed_http_port()
	spawn serve_server_runtime(mut one, managed_http_config(first))
	spawn serve_server_runtime(mut two, managed_http_config(second))
	managed_http_ready(first)
	managed_http_ready(second)
	response := chan string{cap: 1}
	spawn fn [first, response] () {
		result := http.get('http://127.0.0.1:${first}/hold') or { panic(err) }
		assert result.status_code == 200
		response <- result.body
	}()
	managed_http_done(entered)
	mut run := one.websocket.upstream_runs.reserve('held-background') or { panic('reserve') }
	mut registry := &ActiveRuntimeRegistry{}
	registry.register(one, managed_http_config(first))
	registry.register(two, managed_http_config(second))
	done := chan bool{cap: 1}
	spawn fn [mut registry, done] () {
		registry.stop_runtime_transports()
		done <- true
	}()
	deadline := time.now().add(3 * time.second)
	for one.lifecycle.http.accepting() || two.lifecycle.http.accepting() {
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	assert !run.stopped()
	select {
		_ := <-done {
			panic('shutdown overtook HTTP')
		}
		else {
		}
	}
	release <- true
	select {
		body := <-response {
			assert body == 'finished'
		}
		3 * time.second {
			panic('response not drained')
		}
	}
	for !run.stopped() {
		assert time.now() < deadline
		time.sleep(time.millisecond)
	}
	one.websocket.upstream_runs.release('held-background', mut run)
	managed_http_done(done)
}

fn test_admin_http_start_stop_overlap_cannot_publish_a_late_listener() {
	for _ in 0 .. 5 {
		mut app := &App{}
		port := managed_http_port()
		assert AdminPlaneRuntime.start(mut app, '127.0.0.1', port, '')
		managed_http_wait(app.request_http_ingress_stop())
		assert !AdminPlaneRuntime.start(mut app, '127.0.0.1', port, '')
		mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { panic(err) }
		listener.close() or { panic(err) }
	}
}

fn test_shared_app_can_serve_and_drain_multiple_http_endpoints() {
	mut app := &App{}
	first := managed_http_port()
	second := managed_http_port()
	spawn serve_server_runtime(mut app, managed_http_config(first))
	spawn serve_server_runtime(mut app, managed_http_config(second))
	managed_http_ready(first)
	managed_http_ready(second)
	app.init_server(&veb.Server{}) // Same SDK lifecycle placeholder as the TLS backend.
	app.before_accept_loop()
	managed_http_wait(app.request_http_ingress_stop())
	for port in [first, second] {
		mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { panic(err) }
		listener.close() or { panic(err) }
	}
}
