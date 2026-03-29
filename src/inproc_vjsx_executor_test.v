module main

import net.http
import os
import json
import time

fn codexbot_ts_feishu_payload(text string, chat_id string, message_id string) string {
	content_json := json.encode({
		'text': text
	})
	return '{"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","content":${json.encode(content_json)}}}}'
}

fn codexbot_ts_feishu_thread_payload(text string, chat_id string, message_id string, root_id string, parent_id string) string {
	content_json := json.encode({
		'text': text
	})
	return '{"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","root_id":"${root_id}","parent_id":"${parent_id}","content":${json.encode(content_json)}}}}'
}

fn codexbot_ts_with_temp_db(db_name string, run fn (string)) {
	with_temp_sqlite_db_env('CODEXBOT_TS_DB_PATH', db_name, run)
}

fn inproc_vjsx_test_lane_host_signature(executor InProcVjsxExecutor, idx int) string {
	if isnil(executor.state) {
		return ''
	}
	mut state := executor.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if idx < 0 || idx >= state.hosts.len {
		return ''
	}
	return state.hosts[idx].source_signature
}

fn test_inproc_vjsx_executor_lane_temp_root_uses_system_temp_cache() {
	app_entry := '/tmp/demo/hello-handler.mts'
	temp_root := vjsx_lane_temp_root(app_entry, 2)
	assert temp_root.starts_with(os.join_path(os.temp_dir(), 'vhttpd_vjsx'))
	assert temp_root.contains('hello-handler.mts')
	assert temp_root.ends_with('lane_2.vjsbuild')
	assert !temp_root.contains(app_entry + '.lane_2.vjsbuild')
}

fn test_inproc_vjsx_executor_source_signature_respects_include_and_exclude_globs() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_signature_scope_test')
	os.mkdir_all(os.join_path(temp_dir, 'node_modules')) or { panic(err) }
	app_file := os.join_path(temp_dir, 'app.mts')
	keep_file := os.join_path(temp_dir, 'keep.mts')
	ignore_file := os.join_path(temp_dir, 'ignore.mts')
	dep_file := os.join_path(temp_dir, 'node_modules', 'dep.mts')
	os.write_file(app_file, 'export default function handle(ctx) { return ctx.text("ok"); }\n') or {
		panic(err)
	}
	os.write_file(keep_file, 'export const value = "keep-v1";\n') or { panic(err) }
	os.write_file(ignore_file, 'export const value = "ignore-v1";\n') or { panic(err) }
	os.write_file(dep_file, 'export const value = "dep-v1";\n') or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	config := VjsxRuntimeFacadeConfig{
		app_entry:         app_file
		module_root:       temp_dir
		signature_root:    temp_dir
		signature_include: ['**/*.mts']
		signature_exclude: ['ignore.mts']
		thread_count:      1
	}
	sig_before := vjsx_source_signature_for_config(config)
	os.write_file(ignore_file, 'export const value = "ignore-v2";\n') or { panic(err) }
	sig_after_ignored := vjsx_source_signature_for_config(config)
	assert sig_after_ignored == sig_before
	os.write_file(dep_file, 'export const value = "dep-v2";\n') or { panic(err) }
	sig_after_dep := vjsx_source_signature_for_config(config)
	assert sig_after_dep == sig_before
	os.write_file(keep_file, 'export const value = "keep-v2-longer";\n') or { panic(err) }
	sig_after_keep := vjsx_source_signature_for_config(config)
	assert sig_after_keep != sig_before
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	assert outcome.response.body.contains('"capabilities":{"http":true,"stream":false,"websocket":false,"websocketUpstream":false,"fs":false,"process":false,"network":false}')
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	defer {
		executor.close()
	}
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
	assert next.id == 'lane_0'
	executor.release_lane('lane_0')
	snapshot := executor.lane_snapshot()
	assert snapshot[0].healthy == false
	assert snapshot[0].dirty == true
	assert snapshot[0].last_error == 'boom'
	assert snapshot[1].served_requests == 1
	assert snapshot[1].healthy == true
	assert snapshot[1].dirty == false
	assert snapshot[0].inflight == 0
	assert snapshot[1].inflight == 0
}

fn test_inproc_vjsx_executor_rebuilds_lane_host_when_source_signature_changes() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_signature_rebuild_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'app.mts')
	helper_file := os.join_path(temp_dir, 'helper.mts')
	os.write_file(helper_file, 'export const message = "v1";\n') or { panic(err) }
	os.write_file(app_file, 'import { message } from "./helper.mts";\nexport default function handle(ctx) { return ctx.text(message, 200); }\n') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
	})
	defer {
		executor.close()
	}
	mut app := App{}
	req := http.Request{
		method: .get
		url:    '/hello'
		host:   'example.test'
	}
	first := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/hello'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_signature_rebuild_1'
		request_id:  'req_signature_rebuild_1'
	}) or { panic(err) }
	assert first.response.body == 'v1'
	first_signature := inproc_vjsx_test_lane_host_signature(executor, 0)
	assert first_signature != ''
	os.write_file(helper_file, 'export const message = "v2";\n') or { panic(err) }
	second := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/hello'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_signature_rebuild_2'
		request_id:  'req_signature_rebuild_2'
	}) or { panic(err) }
	assert second.response.body == 'v2'
	second_signature := inproc_vjsx_test_lane_host_signature(executor, 0)
	assert second_signature != ''
	assert second_signature != first_signature
}

fn test_inproc_vjsx_executor_lane_error_marks_dirty_and_recovers_after_source_fix() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_lane_recover_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'app.mts')
	state_file := os.join_path(temp_dir, 'state.mts')
	os.write_file(state_file, 'export const mode = "boom";\n') or { panic(err) }
	os.write_file(app_file, 'import { mode } from "./state.mts";\nexport default function handle() { if (mode === "boom") { throw new Error("boom"); } return { status: 200, headers: { "content-type": "text/plain; charset=utf-8" }, body: "mode:" + mode }; }\n') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
	})
	defer {
		executor.close()
	}
	mut app := App{}
	req := http.Request{
		method: .get
		url:    '/recover'
		host:   'example.test'
	}
	mut first_err := ''
	executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/recover'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_lane_recover_1'
		request_id:  'req_lane_recover_1'
	}) or { first_err = err.msg() }
	assert first_err.starts_with('inproc_vjsx_executor_handler_failed:')
	snapshot_after_error := executor.lane_snapshot()
	assert snapshot_after_error[0].healthy == false
	assert snapshot_after_error[0].dirty == true
	assert snapshot_after_error[0].last_error.contains('boom')
	os.write_file(state_file, 'export const mode = "ok";\n') or { panic(err) }
	recovered := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/recover'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_lane_recover_2'
		request_id:  'req_lane_recover_2'
	}) or { panic(err) }
	assert recovered.response.body == 'mode:ok'
	snapshot_after_recover := executor.lane_snapshot()
	assert snapshot_after_recover[0].healthy == true
	assert snapshot_after_recover[0].dirty == false
	assert snapshot_after_recover[0].last_error == ''
}

fn inproc_vjsx_release_lane_after_delay(executor InProcVjsxExecutor, lane_id string, delay_ms int) {
	time.sleep(delay_ms * time.millisecond)
	executor.release_lane(lane_id)
}

fn test_inproc_vjsx_executor_acquire_next_lane_waits_for_release() {
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count: 1
		app_entry:    'app/main.ts'
	})
	defer {
		executor.close()
	}
	executor.bootstrap_placeholder() or { assert false }
	first := executor.select_next_lane() or { panic(err) }
	assert first.id == 'lane_0'
	releaser := spawn inproc_vjsx_release_lane_after_delay(executor, first.id, 20)
	waited := executor.acquire_next_lane(200) or { panic(err) }
	assert waited.id == 'lane_0'
	executor.release_lane(waited.id)
	releaser.wait()
	snapshot := executor.lane_snapshot()
	assert snapshot[0].inflight == 0
}

fn test_inproc_vjsx_executor_bootstrap_requires_app_entry() {
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count: 1
	})
	defer {
		executor.close()
	}
	executor.bootstrap_placeholder() or {
		assert err.msg() == 'inproc_vjsx_executor_missing_app_entry'
		assert executor.facade_snapshot().last_error == 'inproc_vjsx_executor_missing_app_entry'
		return
	}
	assert false
}

fn test_inproc_vjsx_executor_dispatch_websocket_upstream_supports_named_export_handler() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_ws_upstream_named_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'bot-handler.mts')
	os.write_file(app_file, '
export function websocket_upstream(frame) {
  const payload = frame.payloadJson({ text: "fallback" });
  return {
    handled: true,
    commands: [
      {
        type: "provider.message.send",
        provider: frame.provider,
        instance: frame.instance,
        target: frame.target,
        target_type: frame.targetType || "chat_id",
        message_type: "text",
        text: "echo " + payload.text,
        metadata: {
          event_type: frame.eventType,
          dispatch_kind: frame.runtime.dispatchKind
        }
      }
    ]
  };
}
') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
	})
	defer {
		executor.close()
	}
	mut app := App{}
	resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
		mode:        'websocket_upstream'
		event:       'message'
		id:          'upstream_req_001'
		provider:    'feishu'
		instance:    'main'
		trace_id:    'trace_upstream_001'
		event_type:  'im.message.receive_v1'
		message_id:  'om_test_001'
		target:      'chat_test_001'
		target_type: 'chat_id'
		payload:     '{"text":"ping"}'
		received_at: 1710000000
		metadata:    {
			'source': 'test'
		}
	}) or { panic(err) }
	assert resp.mode == 'websocket_upstream'
	assert resp.event == 'result'
	assert resp.id == 'upstream_req_001'
	assert resp.handled
	assert resp.commands.len == 1
	assert resp.commands[0].type_ == 'provider.message.send'
	assert resp.commands[0].provider == 'feishu'
	assert resp.commands[0].instance == 'main'
	assert resp.commands[0].target == 'chat_test_001'
	assert resp.commands[0].target_type == 'chat_id'
	assert resp.commands[0].message_type == 'text'
	assert resp.commands[0].text == 'echo ping'
	assert resp.commands[0].metadata['event_type'] == 'im.message.receive_v1'
	assert resp.commands[0].metadata['dispatch_kind'] == 'websocket_upstream'
}

fn test_inproc_vjsx_executor_dispatch_websocket_upstream_exposes_runtime_read_text_file() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_ws_upstream_fs_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'bot-handler.mts')
	data_file := os.join_path(temp_dir, 'payload.txt')
	os.write_file(data_file, 'hello from runtime.readTextFile') or { panic(err) }
	os.write_file(app_file,
		'
export function websocket_upstream(frame) {
  return {
    handled: true,
    commands: [
      {
        type: "provider.message.send",
        provider: frame.provider,
        instance: frame.instance,
        target: frame.target,
        target_type: frame.targetType || "chat_id",
        message_type: "text",
        text: frame.runtime.readTextFile("' +
		data_file.replace('\\', '\\\\').replace('"', '\\"') + '", "fallback")
      }
    ]
  };
}
') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
		os.rm(data_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
		enable_fs:       true
	})
	defer {
		executor.close()
	}
	mut app := App{}
	resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
		mode:        'websocket_upstream'
		event:       'message'
		id:          'upstream_fs_req_001'
		provider:    'feishu'
		instance:    'main'
		trace_id:    'trace_upstream_fs_001'
		event_type:  'im.message.receive_v1'
		message_id:  'om_test_fs_001'
		target:      'chat_test_fs_001'
		target_type: 'chat_id'
		payload:     '{"text":"ping"}'
		received_at: 1710000000
	}) or { panic(err) }
	assert resp.handled
	assert resp.commands.len == 1
	assert resp.commands[0].text == 'hello from runtime.readTextFile'
}

fn test_inproc_vjsx_executor_dispatch_websocket_upstream_can_parse_codex_session_jsonl() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_ws_upstream_session_parse_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'bot-handler.mts')
	session_file := os.join_path(temp_dir, 'session.jsonl')
	os.write_file(session_file, '{"timestamp":"2026-03-27T14:00:02.896Z","type":"event_msg","payload":{"type":"agent_message","message":"final answer from parser test","phase":"final_answer"}}\n') or {
		panic(err)
	}
	os.write_file(app_file,
		'
function readFinalAnswerFromSessionPath(runtime, sessionPath) {
  const raw = runtime.readTextFile(sessionPath, "");
  if (typeof raw !== "string" || raw.trim() === "") {
    return "";
  }
  const lines = raw.split(/\\r?\\n/).filter(Boolean);
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    let row;
    try {
      row = JSON.parse(lines[i]);
    } catch (_) {
      continue;
    }
    const payload = row && typeof row === "object" ? row.payload : undefined;
    if (!payload || typeof payload !== "object") {
      continue;
    }
    if (row.type === "event_msg" && payload.type === "agent_message" && typeof payload.message === "string" && payload.message.trim() !== "") {
      return payload.message.trim();
    }
  }
  return "";
}

export function websocket_upstream(frame) {
  return {
    handled: true,
    commands: [
      {
        type: "provider.message.send",
        provider: frame.provider,
        instance: frame.instance,
        target: frame.target,
        target_type: frame.targetType || "chat_id",
        message_type: "text",
        text: readFinalAnswerFromSessionPath(frame.runtime, "' +
		session_file.replace('\\', '\\\\').replace('"', '\\"') + '")
      }
    ]
  };
}
') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
		os.rm(session_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
		enable_fs:       true
	})
	defer {
		executor.close()
	}
	mut app := App{}
	resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
		mode:        'websocket_upstream'
		event:       'message'
		id:          'upstream_session_parse_req_001'
		provider:    'feishu'
		instance:    'main'
		trace_id:    'trace_upstream_session_parse_001'
		event_type:  'im.message.receive_v1'
		message_id:  'om_test_session_parse_001'
		target:      'chat_test_session_parse_001'
		target_type: 'chat_id'
		payload:     '{"text":"ping"}'
		received_at: 1710000000
	}) or { panic(err) }
	assert resp.handled
	assert resp.commands.len == 1
	assert resp.commands[0].text == 'final answer from parser test'
}

fn test_inproc_vjsx_executor_dispatch_websocket_upstream_read_text_file_survives_await() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_ws_upstream_fs_await_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'bot-handler.mts')
	data_file := os.join_path(temp_dir, 'payload.txt')
	os.write_file(data_file, 'hello after await') or { panic(err) }
	os.write_file(app_file,
		'
export async function websocket_upstream(frame) {
  await Promise.resolve();
  return {
    handled: true,
    commands: [
      {
        type: "provider.message.send",
        provider: frame.provider,
        instance: frame.instance,
        target: frame.target,
        target_type: frame.targetType || "chat_id",
        message_type: "text",
        text: frame.runtime.readTextFile("' +
		data_file.replace('\\', '\\\\').replace('"', '\\"') + '", "fallback")
      }
    ]
  };
}
') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
		os.rm(data_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
		enable_fs:       true
	})
	defer {
		executor.close()
	}
	mut app := App{}
	resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
		mode:        'websocket_upstream'
		event:       'message'
		id:          'upstream_fs_await_req_001'
		provider:    'feishu'
		instance:    'main'
		trace_id:    'trace_upstream_fs_await_001'
		event_type:  'im.message.receive_v1'
		message_id:  'om_test_fs_await_001'
		target:      'chat_test_fs_await_001'
		target_type: 'chat_id'
		payload:     '{"text":"ping"}'
		received_at: 1710000000
	}) or { panic(err) }
	assert resp.handled
	assert resp.commands.len == 1
	assert resp.commands[0].text == 'hello after await'
}

fn test_inproc_vjsx_executor_dispatch_websocket_upstream_read_text_file_survives_import_helper() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_ws_upstream_fs_import_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'app.mts')
	helper_file := os.join_path(temp_dir, 'helper.mjs')
	data_file := os.join_path(temp_dir, 'payload.txt')
	os.write_file(data_file, 'hello from import helper') or { panic(err) }
	os.write_file(helper_file, '
export function readViaHelper(runtime, path) {
  return runtime.readTextFile(path, "fallback");
}
') or {
		panic(err)
	}
	os.write_file(app_file,
		'
import { readViaHelper } from "./helper.mjs";

export function websocket_upstream(frame) {
  return {
    handled: true,
    commands: [
      {
        type: "provider.message.send",
        provider: frame.provider,
        instance: frame.instance,
        target: frame.target,
        target_type: frame.targetType || "chat_id",
        message_type: "text",
        text: readViaHelper(frame.runtime, "' +
		data_file.replace('\\', '\\\\').replace('"', '\\"') + '")
      }
    ]
  };
}
') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
		os.rm(helper_file) or {}
		os.rm(data_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
		enable_fs:       true
	})
	defer {
		executor.close()
	}
	mut app := App{}
	resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
		mode:        'websocket_upstream'
		event:       'message'
		id:          'upstream_fs_import_req_001'
		provider:    'feishu'
		instance:    'main'
		trace_id:    'trace_upstream_fs_import_001'
		event_type:  'im.message.receive_v1'
		message_id:  'om_test_fs_import_001'
		target:      'chat_test_fs_import_001'
		target_type: 'chat_id'
		payload:     '{"text":"ping"}'
		received_at: 1710000000
	}) or { panic(err) }
	assert resp.handled
	assert resp.commands.len == 1
	assert resp.commands[0].text == 'hello from import helper'
}

fn test_inproc_vjsx_executor_dispatch_websocket_upstream_read_text_file_after_sqlite_await() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_ws_upstream_fs_sqlite_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'app.mts')
	data_file := os.join_path(temp_dir, 'payload.txt')
	db_file := os.join_path(temp_dir, 'state.sqlite')
	os.write_file(data_file, 'hello after sqlite await') or { panic(err) }
	os.write_file(app_file,
		'
import { open } from "sqlite";

let dbPromise;

async function db(path) {
  if (!dbPromise) {
    dbPromise = open({ path }).then(async (database) => {
      await database.exec("create table if not exists test_state (id integer primary key, value text not null)");
      return database;
    });
  }
  return dbPromise;
}

export async function websocket_upstream(frame) {
  const database = await db("' +
		db_file.replace('\\', '\\\\').replace('"', '\\"') +
		'");
  await database.exec("insert into test_state (value) values (?)", ["ok"]);
  return {
    handled: true,
    commands: [
      {
        type: "provider.message.send",
        provider: frame.provider,
        instance: frame.instance,
        target: frame.target,
        target_type: frame.targetType || "chat_id",
        message_type: "text",
        text: frame.runtime.readTextFile("' +
		data_file.replace('\\', '\\\\').replace('"', '\\"') + '", "fallback")
      }
    ]
  };
}
') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
		os.rm(data_file) or {}
		os.rm(db_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
		enable_fs:       true
	})
	defer {
		executor.close()
	}
	mut app := App{}
	resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
		mode:        'websocket_upstream'
		event:       'message'
		id:          'upstream_fs_sqlite_req_001'
		provider:    'feishu'
		instance:    'main'
		trace_id:    'trace_upstream_fs_sqlite_001'
		event_type:  'im.message.receive_v1'
		message_id:  'om_test_fs_sqlite_001'
		target:      'chat_test_fs_sqlite_001'
		target_type: 'chat_id'
		payload:     '{"text":"ping"}'
		received_at: 1710000000
	}) or { panic(err) }
	assert resp.handled
	assert resp.commands.len == 1
	assert resp.commands[0].text == 'hello after sqlite await'
}

fn test_inproc_vjsx_executor_dispatch_websocket_upstream_returns_unhandled_when_missing_handler() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_ws_upstream_missing_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'http-only-handler.mts')
	os.write_file(app_file, 'export default function handle(ctx) { return ctx.ok({ ok: true, path: ctx.path }); }') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
	})
	defer {
		executor.close()
	}
	mut app := App{}
	resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
		mode:       'websocket_upstream'
		event:      'message'
		id:         'upstream_req_002'
		provider:   'feishu'
		instance:   'main'
		trace_id:   'trace_upstream_002'
		event_type: 'im.message.receive_v1'
		target:     'chat_test_002'
	}) or { panic(err) }
	assert resp.mode == 'websocket_upstream'
	assert resp.event == 'result'
	assert resp.id == 'upstream_req_002'
	assert !resp.handled
	assert resp.commands.len == 0
}

fn test_inproc_vjsx_executor_supports_default_object_bot_entry_shape() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_bot_entry_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'bot-entry.mts')
	os.write_file(app_file, '
const bot = {
  prefix: "bot",
  http(ctx) {
    return ctx.json({ ok: true, prefix: this.prefix, dispatchKind: ctx.runtime.dispatchKind }, 209);
  },
  websocket_upstream(frame) {
    const payload = frame.payloadJson({ text: "fallback" });
    return [
      {
        type: "provider.message.send",
        provider: frame.provider,
        instance: frame.instance,
        target: frame.target,
        target_type: frame.targetType || "chat_id",
        message_type: "text",
        text: this.prefix + ":" + payload.text,
        metadata: {
          lane_id: frame.runtime.laneId,
          event: frame.event
        }
      }
    ];
  }
};

export default bot;
') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
	})
	defer {
		executor.close()
	}
	mut app := App{}
	http_outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/bot'
		req:         http.Request{
			method: .get
			url:    '/bot'
			host:   'example.test'
		}
		remote_addr: '127.0.0.1'
		trace_id:    'trace_bot_http'
		request_id:  'req_bot_http'
	}) or { panic(err) }
	assert http_outcome.response.status == 209
	assert http_outcome.response.body.contains('"prefix":"bot"')
	assert http_outcome.response.body.contains('"dispatchKind":"http"')

	upstream_resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
		mode:        'websocket_upstream'
		event:       'message'
		id:          'upstream_req_003'
		provider:    'feishu'
		instance:    'main'
		trace_id:    'trace_upstream_003'
		event_type:  'im.message.receive_v1'
		message_id:  'om_test_003'
		target:      'chat_test_003'
		target_type: 'chat_id'
		payload:     '{"text":"hello"}'
		received_at: 1710000001
	}) or { panic(err) }
	assert upstream_resp.handled
	assert upstream_resp.commands.len == 1
	assert upstream_resp.commands[0].text == 'bot:hello'
	assert upstream_resp.commands[0].metadata['event'] == 'message'
	assert upstream_resp.commands[0].metadata['lane_id'] != ''
}

fn test_inproc_vjsx_executor_runs_startup_and_app_startup_hooks() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_startup_hooks_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'startup-hooks.mts')
	os.write_file(app_file, '
let laneStartupCount = 0;
let appStartupCount = 0;

const app = {
  async startup(runtime) {
    laneStartupCount += 1;
    return [];
  },
  async app_startup(runtime) {
    appStartupCount += 1;
    return [];
  },
  http(ctx) {
    return ctx.json({
      laneId: ctx.runtime.laneId,
      laneStartupCount,
      appStartupCount
    }, 200);
  }
};

export default app;
') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    2
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
	})
	defer {
		executor.close()
	}
	mut app := App{}
	first := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/startup'
		req:         http.Request{
			method: .get
			url:    '/startup'
			host:   'example.test'
		}
		remote_addr: '127.0.0.1'
		trace_id:    'trace_startup_1'
		request_id:  'req_startup_1'
	}) or { panic(err) }
	second := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/startup'
		req:         http.Request{
			method: .get
			url:    '/startup'
			host:   'example.test'
		}
		remote_addr: '127.0.0.1'
		trace_id:    'trace_startup_2'
		request_id:  'req_startup_2'
	}) or { panic(err) }
	assert first.response.status == 200
	assert second.response.status == 200
	assert first.response.body.contains('"laneStartupCount":1')
	assert second.response.body.contains('"laneStartupCount":1')
	assert first.response.body.contains('"appStartupCount":1')
	assert second.response.body.contains('"appStartupCount":0')
}

fn test_inproc_vjsx_executor_executes_app_startup_commands_once() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_executor_app_startup_commands_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'app-startup-commands.mts')
	os.write_file(app_file, '
let appStartupCount = 0;

const app = {
  async app_startup(runtime) {
    appStartupCount += 1;
    const command = {};
    command.type = "provider.instance.upsert";
    command.provider = "demo";
    command.instance = "main";
    command.content = "{\\"value\\":\\"startup_value\\"}";
    command.metadata = { desired_state: "connected" };
    return { commands: [command] };
  },
  http(ctx) {
    return ctx.json({ appStartupCount }, 200);
  }
};

export default app;
') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
	})
	defer {
		executor.close()
	}
	mut app := App{
		feishu_apps:    map[string]FeishuAppConfig{}
		feishu_runtime: map[string]FeishuProviderRuntime{}
	}
	resp := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/startup-command'
		req:         http.Request{
			method: .get
			url:    '/startup-command'
			host:   'example.test'
		}
		remote_addr: '127.0.0.1'
		trace_id:    'trace_startup_command'
		request_id:  'req_startup_command'
	}) or { panic(err) }
	assert resp.response.status == 200
	assert resp.response.body.contains('"appStartupCount":1')
	spec := app.provider_instance_get('demo', 'main') or { panic('missing provider instance spec') }
	assert spec.provider == 'demo'
	assert spec.instance == 'main'
	assert spec.config_json.contains('"value":"startup_value"')
}
