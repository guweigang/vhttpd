module main

import net.http
import os

fn test_inproc_vjsx_executor_lane_temp_root_uses_system_temp_cache() {
	app_entry := '/tmp/demo/hello-handler.mts'
	temp_root := vjsx_lane_temp_root(app_entry, 2)
	assert temp_root.starts_with(os.join_path(os.temp_dir(), 'vhttpd_vjsx'))
	assert temp_root.contains('hello-handler.mts')
	assert temp_root.ends_with('lane_2.vjsbuild')
	assert !temp_root.contains(app_entry + '.lane_2.vjsbuild')
}

fn test_inproc_vjsx_executor_repo_api_demo_handler_runs() {
	app_file := os.join_path(os.dir(@FILE), '..', 'examples', 'vjsx', 'api-demo-handler.mts')
	assert os.exists(app_file)
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     os.dir(app_file)
		runtime_profile: 'node'
	})
	mut app := App{}
	req := http.Request{
		method: .get
		url:    '/hello?name=repo-demo'
		host:   'example.test'
	}
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/hello?name=repo-demo'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_repo_demo'
		request_id:  'req_repo_demo'
	}) or { panic(err) }
	assert outcome.response.status == 200
	assert outcome.response.body.contains('"kind":"hello"')
	assert outcome.response.body.contains('"name":"repo-demo"')
	assert outcome.response.body.contains('"executor":"vjsx"')
	assert outcome.response.body.contains('"wantsJson":true')
}

fn test_inproc_vjsx_executor_identity_and_lane_bootstrap() {
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    3
		runtime_profile: 'node'
	})
	assert executor.kind() == 'vjsx'
	assert executor.provider() == 'vjsx'
	assert executor.lane_count() == 3
	lanes := executor.lane_snapshot()
	assert lanes[0].id == 'lane_0'
	assert !executor.facade_snapshot().bootstrapped
	assert executor.facade_snapshot().config.runtime_profile == 'node'
}

fn test_inproc_vjsx_executor_methods_are_explicitly_not_ready() {
	mut app := App{}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{})
	req := HttpLogicDispatchRequest{}
	executor.dispatch_http(mut app, req) or {
		assert err.msg() == 'inproc_vjsx_executor_no_lanes'
		return
	}
	assert false
}

fn test_inproc_vjsx_executor_dispatch_http_runs_js_handler() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.js')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = (ctx) => { ctx.setHeader("x-test", ctx.method); return ctx.json({ ok: true, path: ctx.path, method: ctx.request.method }, 201); };') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'script'
	})
	mut app := App{}
	mut req := http.Request{
		method: .post
		url:    '/hello?name=codex'
		host:   'example.test'
		data:   '{"x":1}'
	}
	req.add_custom_header('content-type', 'application/json') or { panic(err) }
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'POST'
		path:        '/hello?name=codex'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_001'
		request_id:  'req_001'
	}) or { panic(err) }
	assert outcome.kind == .response
	assert outcome.response.status == 201
	assert outcome.response.headers['x-test'] == 'POST'
	assert outcome.response.headers['content-type'] == 'application/json; charset=utf-8'
	assert outcome.response.body.contains('"ok":true')
	assert outcome.response.body.contains('"path":"/hello"')
	assert executor.lane_snapshot()[0].served_requests == 1
	assert executor.facade_snapshot().bootstrapped
}

fn test_inproc_vjsx_executor_dispatch_http_supports_implicit_ctx_response() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_ctx_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.js')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = async (ctx) => { ctx.status(202); ctx.setHeader("x-flow", "implicit"); ctx.text("hello " + ctx.request.query.name); };') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'script'
	})
	mut app := App{}
	req := http.Request{
		method: .get
		url:    '/hello?name=codex'
		host:   'example.test'
	}
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/hello?name=codex'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_002'
		request_id:  'req_002'
	}) or { panic(err) }
	assert outcome.response.status == 202
	assert outcome.response.headers['x-flow'] == 'implicit'
	assert outcome.response.headers['content-type'] == 'text/plain; charset=utf-8'
	assert outcome.response.body == 'hello codex'
}

fn test_inproc_vjsx_executor_dispatch_http_exposes_runtime_facade() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_runtime_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.js')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = (ctx) => ctx.json({ provider: ctx.runtime.provider, executor: ctx.runtime.executor, laneId: ctx.runtime.laneId, requestId: ctx.runtime.requestId, traceId: ctx.runtime.traceId, runtimeProfile: ctx.runtime.runtimeProfile, threadCount: ctx.runtime.threadCount, request: ctx.runtime.request, capabilities: ctx.runtime.capabilities, method: ctx.runtime.method, path: ctx.runtime.path, nowType: typeof ctx.runtime.now(), queryName: ctx.queryParam("name", "guest") }, 207);') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'script'
	})
	mut app := App{}
	req := http.Request{
		method: .get
		url:    '/hello?name=codex'
		host:   'example.test'
	}
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/hello?name=codex'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_runtime'
		request_id:  'req_runtime'
	}) or { panic(err) }
	assert outcome.response.status == 207
	assert outcome.response.body.contains('"provider":"vjsx"')
	assert outcome.response.body.contains('"executor":"vjsx"')
	assert outcome.response.body.contains('"laneId":"lane_0"')
	assert outcome.response.body.contains('"requestId":"req_runtime"')
	assert outcome.response.body.contains('"traceId":"trace_runtime"')
	assert outcome.response.body.contains('"runtimeProfile":"script"')
	assert outcome.response.body.contains('"threadCount":1')
	assert outcome.response.body.contains('"request":{"id":"req_runtime"')
	assert outcome.response.body.contains('"traceId":"trace_runtime"')
	assert outcome.response.body.contains('"method":"GET"')
	assert outcome.response.body.contains('"path":"/hello"')
	assert outcome.response.body.contains('"url":"/hello"')
	assert outcome.response.body.contains('"capabilities":{"http":true,"stream":false,"websocket":false,"fs":false,"process":false,"network":false}')
	assert outcome.response.body.contains('"method":"GET"')
	assert outcome.response.body.contains('"path":"/hello"')
	assert outcome.response.body.contains('"nowType":"number"')
	assert outcome.response.body.contains('"queryName":"codex"')
}

fn test_inproc_vjsx_executor_dispatch_http_exposes_request_environment_facade() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_request_env_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.js')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = (ctx) => ctx.json({ runtimeRequest: ctx.runtime.request, requestEnv: { target: ctx.target, href: ctx.href, origin: ctx.origin, scheme: ctx.scheme, host: ctx.host, port: ctx.port, protocolVersion: ctx.protocolVersion, remoteAddr: ctx.remoteAddr, ip: ctx.ip, server: ctx.server } }, 214);') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'script'
	})
	mut app := App{}
	mut req := http.Request{
		method: .get
		url:    '/hello?name=codex'
		host:   'example.test:8443'
	}
	req.add_custom_header('x-forwarded-proto', 'https') or { panic(err) }
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/hello?name=codex'
		req:         req
		remote_addr: '127.0.0.9'
		trace_id:    'trace_request_env'
		request_id:  'req_request_env'
	}) or { panic(err) }
	assert outcome.response.status == 214
	assert outcome.response.body.contains('"target":"/hello?name=codex"')
	assert outcome.response.body.contains('"href":"https://example.test:8443/hello?name=codex"')
	assert outcome.response.body.contains('"origin":"https://example.test:8443"')
	assert outcome.response.body.contains('"scheme":"https"')
	assert outcome.response.body.contains('"host":"example.test"')
	assert outcome.response.body.contains('"port":"8443"')
	assert outcome.response.body.contains('"protocolVersion":"1.1"')
	assert outcome.response.body.contains('"remoteAddr":"127.0.0.9"')
	assert outcome.response.body.contains('"ip":"127.0.0.9"')
	assert outcome.response.body.contains('"server":{')
	assert outcome.response.body.contains('"host":"example.test"')
	assert outcome.response.body.contains('"port":"8443"')
	assert outcome.response.body.contains('"remote_addr":"127.0.0.9"')
	assert outcome.response.body.contains('"url":"/hello?name=codex"')
}

fn test_inproc_vjsx_executor_dispatch_http_exposes_runtime_snapshot() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_snapshot_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.js')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = (ctx) => ctx.json({ snapshot: ctx.runtime.snapshot(), laneId: ctx.runtime.laneId }, 213);') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'script'
	})
	mut app := App{
		worker_backend: WorkerBackendRuntime{
			queue_capacity:   8
			queue_timeout_ms: 25
		}
	}
	req := http.Request{
		method: .get
		url:    '/snapshot'
		host:   'example.test'
	}
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/snapshot'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_snapshot'
		request_id:  'req_snapshot'
	}) or { panic(err) }
	assert outcome.response.status == 213
	assert outcome.response.body.contains('"laneId":"lane_0"')
	assert outcome.response.body.contains('"worker_pool_size":0')
	assert outcome.response.body.contains('"worker_queue_capacity":8')
	assert outcome.response.body.contains('"worker_queue_timeout_ms":25')
	assert outcome.response.body.contains('"capabilities":{"http":true')
	assert outcome.response.body.contains('"stats":{')
}

fn test_inproc_vjsx_executor_dispatch_http_supports_ctx_aliases() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_alias_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.js')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = (ctx) => { ctx.header("x-mode", "alias"); return ctx.html("<h1>" + ctx.queryParam("name", "guest") + "</h1>", 203); };') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'script'
	})
	mut app := App{}
	req := http.Request{
		method: .get
		url:    '/hello?name=codex'
		host:   'example.test'
	}
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/hello?name=codex'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_alias'
		request_id:  'req_alias'
	}) or { panic(err) }
	assert outcome.response.status == 203
	assert outcome.response.headers['x-mode'] == 'alias'
	assert outcome.response.headers['content-type'] == 'text/html; charset=utf-8'
	assert outcome.response.body == '<h1>codex</h1>'
}

fn test_inproc_vjsx_executor_dispatch_http_supports_ctx_helper_methods() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_helper_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.js')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = (ctx) => { const payload = ctx.jsonBody({ fallback: true }); if (!ctx.is("POST")) { return ctx.redirect("/expected", 307); } ctx.type("application/vnd.vhttpd+json"); ctx.setHeader("x-remove-me", "1"); ctx.removeHeader("x-remove-me"); if (ctx.hasHeader("content-type")) { ctx.setHeader("x-seen-content-type", "yes"); } return ctx.ok({ ok: true, code: ctx.code(209).response.status, bodyName: payload.name, requestId: ctx.runtime.request.id, runtimeProfile: ctx.runtime.runtimeProfile, fsEnabled: ctx.runtime.capabilities.fs }); };') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'node'
		enable_fs:       true
	})
	mut app := App{}
	mut req := http.Request{
		method: .post
		url:    '/helpers'
		host:   'example.test'
		data:   '{"name":"codex"}'
	}
	req.add_custom_header('content-type', 'application/json') or { panic(err) }
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'POST'
		path:        '/helpers'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_helper'
		request_id:  'req_helper'
	}) or { panic(err) }
	assert outcome.response.status == 200
	assert outcome.response.headers['content-type'] == 'application/vnd.vhttpd+json'
	assert outcome.response.headers['x-seen-content-type'] == 'yes'
	assert outcome.response.headers['x-remove-me'] == ''
	assert outcome.response.body.contains('"ok":true')
	assert outcome.response.body.contains('"bodyName":"codex"')
	assert outcome.response.body.contains('"requestId":"req_helper"')
	assert outcome.response.body.contains('"runtimeProfile":"node"')
	assert outcome.response.body.contains('"fsEnabled":true')
}

fn test_inproc_vjsx_executor_dispatch_http_supports_semantic_response_helpers() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_semantic_helper_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.js')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = (ctx) => { const mode = ctx.queryParam("mode", "created"); if (mode === "created") return ctx.created({ ok: true, requestId: ctx.requestId }); if (mode === "accepted") return ctx.accepted({ queued: true }); if (mode === "empty") return ctx.noContent(); if (mode === "bad") return ctx.badRequest({ error: "invalid" }); if (mode === "unprocessable") return ctx.unprocessableEntity({ error: "unprocessable" }); if (mode === "problem") return ctx.problem(409, "Conflict", "version mismatch", { error_class: "conflict", title: "ignored" }); return ctx.notFound("missing"); };') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'script'
	})
	mut app := App{}
	modes := {
		'created':       201
		'accepted':      202
		'empty':         204
		'bad':           400
		'unprocessable': 422
		'problem':       409
		'missing':       404
	}
	for mode, expected_status in modes {
		req := http.Request{
			method: .get
			url:    '/semantic?mode=${mode}'
			host:   'example.test'
		}
		outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
			method:      'GET'
			path:        '/semantic?mode=${mode}'
			req:         req
			remote_addr: '127.0.0.1'
			trace_id:    'trace_${mode}'
			request_id:  'req_${mode}'
		}) or { panic(err) }
		assert outcome.response.status == expected_status
		match mode {
			'created' {
				assert outcome.response.headers['content-type'] == 'application/json; charset=utf-8'
				assert outcome.response.body.contains('"ok":true')
				assert outcome.response.body.contains('"requestId":"req_created"')
			}
			'accepted' {
				assert outcome.response.headers['content-type'] == 'application/json; charset=utf-8'
				assert outcome.response.body.contains('"queued":true')
			}
			'empty' {
				assert outcome.response.headers['content-type'] == ''
				assert outcome.response.body == ''
			}
			'bad' {
				assert outcome.response.headers['content-type'] == 'application/json; charset=utf-8'
				assert outcome.response.body.contains('"error":"invalid"')
			}
			'unprocessable' {
				assert outcome.response.headers['content-type'] == 'application/json; charset=utf-8'
				assert outcome.response.body.contains('"error":"unprocessable"')
			}
			'problem' {
				assert outcome.response.headers['content-type'] == 'application/problem+json; charset=utf-8'
				assert outcome.response.body.contains('"status":409')
				assert outcome.response.body.contains('"title":"Conflict"')
				assert outcome.response.body.contains('"detail":"version mismatch"')
				assert outcome.response.body.contains('"error_class":"conflict"')
				assert !outcome.response.body.contains('"title":"ignored"')
			}
			else {
				assert outcome.response.headers['content-type'] == 'text/plain; charset=utf-8'
				assert outcome.response.body == 'missing'
			}
		}
	}
}

fn test_inproc_vjsx_executor_dispatch_http_supports_typed_request_helpers() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_typed_helper_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.js')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = (ctx) => ctx.json({ requestId: ctx.requestId, traceId: ctx.traceId, queryLimit: ctx.queryInt("limit", 0), queryDebug: ctx.queryBool("debug", false), cookieSid: ctx.cookie("sid", "none"), retryCount: ctx.headerInt("x-retry-count", 0), dryRun: ctx.headerBool("x-dry-run", false), bodyText: ctx.bodyText("empty"), bodyJsonName: ctx.jsonBody({ name: "fallback" }).name, capabilityHttp: ctx.runtime.capabilities.http, capabilityStream: ctx.runtime.capabilities.stream }, 211);') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'script'
	})
	mut app := App{}
	mut req := http.Request{
		method: .post
		url:    '/typed?limit=7&debug=true'
		host:   'example.test'
		data:   '{"name":"codex"}'
	}
	req.add_custom_header('content-type', 'application/json') or { panic(err) }
	req.add_custom_header('x-retry-count', '3') or { panic(err) }
	req.add_custom_header('x-dry-run', 'yes') or { panic(err) }
	req.add_custom_header('cookie', 'sid=abc123') or { panic(err) }
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'POST'
		path:        '/typed?limit=7&debug=true'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_typed'
		request_id:  'req_typed'
	}) or { panic(err) }
	assert outcome.response.status == 211
	assert outcome.response.body.contains('"requestId":"req_typed"')
	assert outcome.response.body.contains('"traceId":"trace_typed"')
	assert outcome.response.body.contains('"queryLimit":7')
	assert outcome.response.body.contains('"queryDebug":true')
	assert outcome.response.body.contains('"cookieSid":"abc123"')
	assert outcome.response.body.contains('"retryCount":3')
	assert outcome.response.body.contains('"dryRun":true')
	assert outcome.response.body.contains('"bodyText":"{\\"name\\":\\"codex\\"}"')
	assert outcome.response.body.contains('"bodyJsonName":"codex"')
	assert outcome.response.body.contains('"capabilityHttp":true')
	assert outcome.response.body.contains('"capabilityStream":false')
}

fn test_inproc_vjsx_executor_dispatch_http_supports_request_negotiation_helpers() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_negotiation_helper_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.js')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = (ctx) => ctx.json({ contentType: ctx.contentType(), isJson: ctx.isJson(), isHtml: ctx.isHtml(), accepts: ctx.accepts("application/json", "text/html"), acceptsList: ctx.accepts(), wantsJson: ctx.wantsJson(), wantsHtml: ctx.wantsHtml() }, 215);') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'script'
	})
	mut app := App{}
	mut req := http.Request{
		method: .post
		url:    '/negotiate'
		host:   'example.test'
		data:   '{"name":"codex"}'
	}
	req.add_custom_header('content-type', 'application/merge-patch+json; charset=utf-8') or {
		panic(err)
	}
	req.add_custom_header('accept', 'text/html, application/json;q=0.9') or { panic(err) }
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'POST'
		path:        '/negotiate'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_negotiate'
		request_id:  'req_negotiate'
	}) or { panic(err) }
	assert outcome.response.status == 215
	assert outcome.response.body.contains('"contentType":"application/merge-patch+json"')
	assert outcome.response.body.contains('"isJson":true')
	assert outcome.response.body.contains('"isHtml":false')
	assert outcome.response.body.contains('"accepts":"application/json"')
	assert outcome.response.body.contains('"acceptsList":["text/html","application/json"]')
	assert outcome.response.body.contains('"wantsJson":true')
	assert outcome.response.body.contains('"wantsHtml":true')
}

fn test_inproc_vjsx_executor_runtime_emit_writes_event_log() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_emit_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.js')
	event_log := os.join_path(temp_dir, 'events.ndjson')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = (ctx) => { const emitted = ctx.runtime.emit("unit.test", { feature: "emit", count: 2 }); return ctx.json({ emitted }, 212); };') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
		os.rm(event_log) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'script'
	})
	mut app := App{
		event_log: event_log
	}
	req := http.Request{
		method: .get
		url:    '/emit'
		host:   'example.test'
	}
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/emit'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_emit'
		request_id:  'req_emit'
	}) or { panic(err) }
	assert outcome.response.status == 212
	assert outcome.response.body.contains('"emitted":true')
	log_text := os.read_file(event_log) or { panic(err) }
	assert log_text.contains('"type":"vjsx.unit.test"')
	assert log_text.contains('"feature":"emit"')
	assert log_text.contains('"count":"2"')
	assert log_text.contains('"request_id":"req_emit"')
	assert log_text.contains('"trace_id":"trace_emit"')
	assert log_text.contains('"executor":"vjsx"')
	assert log_text.contains('"lane_id":"lane_0"')
}

fn test_inproc_vjsx_executor_dispatch_http_supports_redirect_helper() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_redirect_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.js')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = (ctx) => ctx.redirect("/moved", 308);') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'script'
	})
	mut app := App{}
	req := http.Request{
		method: .get
		url:    '/redirect'
		host:   'example.test'
	}
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/redirect'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_redirect'
		request_id:  'req_redirect'
	}) or { panic(err) }
	assert outcome.response.status == 308
	assert outcome.response.headers['location'] == '/moved'
	assert outcome.response.headers['content-type'] == 'text/plain; charset=utf-8'
	assert outcome.response.body == ''
}

fn test_inproc_vjsx_executor_dispatch_http_supports_typescript_module_entry() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_ts_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.mts')
	os.write_file(app_file, 'function handler(ctx) { return { status: 206, headers: { "content-type": "application/json; charset=utf-8" }, body: JSON.stringify({ ok: true, message: "hello " + ctx.queryParam("name", "guest"), laneId: ctx.runtime.laneId }) }; }\nglobalThis.__vhttpd_handle = handler;\nexport default handler;\n') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'node'
	})
	mut app := App{}
	req := http.Request{
		method: .get
		url:    '/hello?name=typescript'
		host:   'example.test'
	}
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/hello?name=typescript'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_ts'
		request_id:  'req_ts'
	}) or { panic(err) }
	assert outcome.response.status == 206
	assert outcome.response.body.contains('"ok":true')
	assert outcome.response.body.contains('"message":"hello typescript"')
	assert outcome.response.body.contains('"laneId":"lane_0"')
}

fn test_inproc_vjsx_executor_prefers_module_exports_over_compat_global_handle() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_export_priority_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.mjs')
	os.write_file(app_file, 'globalThis.__vhttpd_handle = () => ({ status: 500, headers: { "content-type": "text/plain; charset=utf-8" }, body: "compat-global" });\nexport const handle = () => ({ status: 208, headers: { "content-type": "text/plain; charset=utf-8", "x-entry": "export-handle" }, body: "module-export" });\n') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		runtime_profile: 'node'
	})
	mut app := App{}
	req := http.Request{
		method: .get
		url:    '/entry'
		host:   'example.test'
	}
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/entry'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_export'
		request_id:  'req_export'
	}) or { panic(err) }
	assert outcome.response.status == 208
	assert outcome.response.headers['x-entry'] == 'export-handle'
	assert outcome.response.body == 'module-export'
}

fn test_inproc_vjsx_executor_lane_round_robin_and_health_tracking() {
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count: 2
		app_entry:    'app/main.ts'
	})
	executor.bootstrap_placeholder() or { assert false }
	first := executor.select_next_lane() or { panic(err) }
	second := executor.select_next_lane() or { panic(err) }
	assert first.id == 'lane_0'
	assert second.id == 'lane_1'
	executor.select_next_lane() or { assert err.msg() == 'inproc_vjsx_executor_no_available_lane' }
	executor.record_lane_error('lane_0', 'boom')
	executor.release_lane('lane_0')
	executor.record_lane_success('lane_1')
	executor.release_lane('lane_1')
	next := executor.select_next_lane() or { panic(err) }
	assert next.id == 'lane_1'
	executor.release_lane('lane_1')
	snapshot := executor.lane_snapshot()
	assert snapshot[0].healthy == false
	assert snapshot[0].last_error == 'boom'
	assert snapshot[1].served_requests == 1
	assert snapshot[1].healthy == true
	assert snapshot[0].inflight == 0
	assert snapshot[1].inflight == 0
}

fn test_inproc_vjsx_executor_bootstrap_requires_app_entry() {
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count: 1
	})
	executor.bootstrap_placeholder() or {
		assert err.msg() == 'inproc_vjsx_executor_missing_app_entry'
		assert executor.facade_snapshot().last_error == 'inproc_vjsx_executor_missing_app_entry'
		return
	}
	assert false
}
