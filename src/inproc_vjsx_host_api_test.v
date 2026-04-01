module main

import net.http
import os

fn test_inproc_vjsx_executor_installs_formal_host_api_globals() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_host_api_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.mts')
	os.write_file(app_file, '
export default function handle(ctx) {
  return ctx.json({
    hostApi: typeof globalThis.vhttpdHost === "object",
    emit: typeof globalThis.vhttpdHost?.emit === "function",
    snapshot: typeof globalThis.vhttpdHost?.snapshot === "function",
    readTextFile: typeof globalThis.vhttpdHost?.readTextFile === "function",
    findCodexSessionPath: typeof globalThis.vhttpdHost?.findCodexSessionPath === "function"
  }, 200);
}
') or {
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
		url:    '/host-api'
		host:   'example.test'
	}
	outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/host-api'
		req:         req
		remote_addr: '127.0.0.1'
		trace_id:    'trace_host_api'
		request_id:  'req_host_api'
	}) or { panic(err) }
	assert outcome.response.status == 200
	assert outcome.response.body.contains('"hostApi":true')
	assert outcome.response.body.contains('"emit":true')
	assert outcome.response.body.contains('"snapshot":true')
	assert outcome.response.body.contains('"readTextFile":true')
	assert outcome.response.body.contains('"findCodexSessionPath":true')
}
