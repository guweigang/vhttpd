module main

import net.http
import os

fn test_inproc_vjsx_runtime_exposes_http_fetch_capability() {
	app_file := os.join_path(os.temp_dir(), 'vhttpd_http_fetch_capability_app.mts')
	os.write_file(app_file, 'export default { http(ctx) { return ctx.json({ network: ctx.runtime.capabilities.network, hasHttpFetch: typeof ctx.runtime.httpFetch === "function" }, 200); } };') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     os.dir(app_file)
		build_root:      os.join_path(os.temp_dir(), 'vhttpd_http_fetch_capability_cache')
		runtime_profile: 'node'
		enable_network:  true
	})
	defer {
		executor.close()
	}
	mut app := App{}
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/capabilities'
		req:         http.Request{
			method: .get
			url:    '/capabilities'
			host:   'example.test'
		}
		remote_addr: '127.0.0.1'
		trace_id:    'trace_http_fetch_capability'
		request_id:  'req_http_fetch_capability'
	}) or {
		panic(err)
	}
	assert outcome.kind == .response
	assert outcome.response.status == 200
	assert outcome.response.body.contains('"network":true')
	assert outcome.response.body.contains('"hasHttpFetch":true')
}
