module executor

import net
import net.http
import os
import time
import vjsx

struct AsyncFetchPeer {}

fn (mut _ AsyncFetchPeer) handle(req http.Request) http.Response {
	if req.url == '/slow' { time.sleep(300 * time.millisecond) }
	mut headers := http.new_header()
	// The fixture must release its bounded server workers after each response;
	// pooled idle clients otherwise occupy both workers when VJOBS=2.
	headers.set(.connection, 'close')
	headers.add_custom('x-test', 'native') or { panic(err) }
	return http.Response{ body: if req.url == '/echo' { req.data } else { 'ok' }, header: headers }
}

fn async_fetch_request(path string) HttpLogicDispatchRequest {
	return HttpLogicDispatchRequest{
		method:     'GET'
		path:       path
		req:        http.Request{ method: .get, url: path, host: 'example.test' }
		request_id: path
		trace_id:   path
	}
}

fn async_fetch_dispatch(exec InProcVjsxExecutor, path string) string {
	mut host := NoOpAppFacade{}
	result := exec.dispatch_http_with_host(mut host, async_fetch_request(path)) or { panic(err) }
	assert result.response.status == 200
	return result.response.body
}

fn test_http_fetch_native_parallel_timeout_abort_and_detached_lane_wakeup() {
	listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := listener.addr() or { panic(err) }.port() or { panic(err) }
	mut peer := &http.Server{
		listener:             listener
		addr:                 '127.0.0.1:${port}'
		handler:              AsyncFetchPeer{}
		// Four simultaneous requests plus cancelled transports can overlap.
		worker_num:           8
		accept_timeout:       100 * time.millisecond
		show_startup_message: false
	}
	server_thread := spawn peer.listen_and_serve()
	peer.wait_till_running() or { panic(err) }
	defer {
		peer.stop()
		server_thread.wait()
	}
	root := os.join_path(os.temp_dir(), 'vhttpd-native-fetch-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	entry := os.join_path(root, 'app.js')
	os.write_file(entry, '
		globalThis.detachedFetch = "pending";
		globalThis.__vhttpd_handle = async ctx => {
			const runtime = ctx.runtime;
			const base = "http://127.0.0.1:${port}";
			const check = (yes, message) => { if (!yes) throw Error(message); };
			if (ctx.path === "/parallel") {
				let ticked = false;
				const timer = setTimeout(() => { ticked = true; }, 20);
				const started = Date.now();
				const pending = runtime.httpFetch({url: base + "/slow"});
				check(typeof pending.then === "function", "fetch is not a Promise");
				const results = await Promise.all([pending, runtime.httpFetch({url: base + "/slow"})]);
				clearTimeout(timer);
				check(ticked, "timer starved");
				check(Date.now() - started < 550, "requests serialized");
				check(results.every(r => r.ok && r.status === 200 && r.body === "ok" && r.headers["x-test"] === "native"), "response mismatch");
				return ctx.text("parallel-ok");
			}
			if (ctx.path === "/cancel") {
				const controller = new AbortController();
				const started = Date.now();
				const pending = runtime.httpFetch({url: base + "/slow", signal: controller.signal});
				setTimeout(() => controller.abort(), 20);
				const result = await pending;
				check(!result.ok && result.errorName === "AbortError", "abort failed");
				check(Date.now() - started < 220, "abort not prompt");
				const pre = await runtime.httpFetch({url: base + "/slow", signal: AbortSignal.abort()});
				check(!pre.ok && pre.errorName === "AbortError", "pre-abort failed");
				return ctx.text("cancel-ok");
			}
			if (ctx.path === "/timeout") {
				const started = Date.now();
				const result = await runtime.httpFetch({url: base + "/slow", timeoutMs: 40});
				check(!result.ok && result.errorName === "TimeoutError", "timeout failed");
				check(Date.now() - started < 220, "timeout not prompt");
				const echo = await runtime.httpFetch({url: base + "/echo", method: "POST", body: "after-timeout"});
				check(echo.ok && echo.body === "after-timeout", "recovery failed: " + JSON.stringify(echo));
				return ctx.text("timeout-ok");
			}
			if (ctx.path === "/detached") {
				runtime.httpFetch({url: base + "/slow"}).then(r => { globalThis.detachedFetch = r.ok ? "done" : "failed"; });
				return ctx.text("started");
			}
			return ctx.text(globalThis.detachedFetch);
		};
	') or { panic(err) }
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       entry
		module_root:     root
		runtime_profile: 'node'
		enable_network:  true
	})
	defer { exec.close() }
	assert async_fetch_dispatch(exec, '/parallel') == 'parallel-ok'
	assert async_fetch_dispatch(exec, '/cancel') == 'cancel-ok'
	assert async_fetch_dispatch(exec, '/timeout') == 'timeout-ok'
	assert async_fetch_dispatch(exec, '/detached') == 'started'
	// No incoming request drives the JS loop while the response arrives.
	// Observe state only after acquiring the lane; never pump from this thread.
	deadline := time.now().add(2 * time.second)
	mut finished := false
	for time.now() < deadline {
		time.sleep(10 * time.millisecond)
		lane := exec.acquire_next_lane(1000) or { continue }
		mut state := exec.state
		state.mu.@lock()
		host := state.hosts[0]
		state.mu.unlock()
		value := host.context().eval('globalThis.detachedFetch') or { panic(err) }
		finished = value.to_string() == 'done'
		value.free()
		exec.release_lane(lane.id)
		if finished { break }
	}
	assert finished
	assert async_fetch_dispatch(exec, '/state') == 'done'
	// Multiple request lanes can each overlap their own outgoing requests.
	multi := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    2
		app_entry:       entry
		module_root:     root
		runtime_profile: 'node'
		enable_network:  true
	})
	defer { multi.close() }
	assert async_fetch_dispatch(multi, '/state') == 'pending'
	assert async_fetch_dispatch(multi, '/state') == 'pending'
	clock := time.new_stopwatch()
	left := spawn async_fetch_dispatch(multi, '/parallel')
	right := spawn async_fetch_dispatch(multi, '/parallel')
	assert left.wait() == 'parallel-ok'
	assert right.wait() == 'parallel-ok'
	println('two lanes / four 300ms requests: ${clock.elapsed().milliseconds()}ms')
	assert clock.elapsed() < 550 * time.millisecond
}

fn test_http_fetch_disabled_capability_still_returns_a_promise_in_both_profiles() {
	root := os.join_path(os.temp_dir(), 'vhttpd-fetch-disabled-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	entry := os.join_path(root, 'app.js')
	os.write_file(entry, 'globalThis.__vhttpd_handle = async ctx => {
		const pending = ctx.runtime.httpFetch({url: "http://127.0.0.1:9"}, "disabled");
		if (typeof pending.then !== "function") throw Error("missing Promise");
		return ctx.text(await pending);
	};') or { panic(err) }
	for profile in ['node', 'script'] {
		exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       entry
			runtime_profile: profile
		})
		assert async_fetch_dispatch(exec, '/disabled') == 'disabled'
		exec.close()
	}
}

fn test_async_completion_alone_wakes_idle_lane_without_a_js_timer() {
	root := os.join_path(os.temp_dir(), 'vhttpd-async-wake-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	entry := os.join_path(root, 'app.js')
	os.write_file(entry, 'globalThis.__vhttpd_handle = ctx => ctx.text("ok"); globalThis.asyncWoke = false;') or { panic(err) }
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{ thread_count: 1, app_entry: entry, runtime_profile: 'node' })
	defer { exec.close() }
	exec.bootstrap_placeholder() or { panic(err) }
	lane := exec.acquire_next_lane(1000) or { panic(err) }
	exec.ensure_lane_host(0) or { panic(err) }
	mut state := exec.state
	state.mu.@lock()
	host := state.hosts[0]
	state.mu.unlock()
	mut session := host.session_handle() or { panic('missing session') }
	operation := session.start_host_async_operation(vjsx.RuntimeHostAsyncOptions{ kind: 'idle-test' }) or { panic(err) }
	global := host.context().js_global()
	global.set('__wakePromise', operation.promise)
	global.free()
	operation.promise.free()
	setup := host.context().eval('__wakePromise.then(() => globalThis.asyncWoke = true)') or { panic(err) }
	setup.free()
	exec.release_lane(lane.id)
	port := operation.completion
	worker := spawn fn [port] () {
		time.sleep(20 * time.millisecond)
		assert port.resolve_text('ready')
	}()
	worker.wait()
	deadline := time.now().add(time.second)
	mut woke := false
	for time.now() < deadline {
		time.sleep(5 * time.millisecond)
		lease := exec.acquire_next_lane(1000) or { continue }
		value := host.context().eval('globalThis.asyncWoke') or { panic(err) }
		woke = value.to_bool()
		value.free()
		exec.release_lane(lease.id)
		if woke { break }
	}
	assert woke
}
