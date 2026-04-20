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

fn test_inproc_vjsx_runtime_session_store_persists_across_requests() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_session_store_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.mts')
	os.write_file(app_file, '
export default function handle(ctx) {
  const store = ctx.runtime.sessionStore("relay");
  if (ctx.path === "/set") {
    return ctx.json({
      ok: store.set("srv:test", { count: 1, status: "ready" }, { ttlMs: 60000 }),
      existsAfterSet: store.exists("srv:test")
    }, 200);
  }
  return ctx.json({
    value: store.get("srv:test", null),
    exists: store.exists("srv:test")
  }, 200);
}
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
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
	set_outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/set'
		req:         http.Request{
			method: .get
			url:    '/set'
			host:   'example.test'
		}
		remote_addr: '127.0.0.1'
		trace_id:    'trace_session_store_set'
		request_id:  'req_session_store_set'
	}) or { panic(err) }
	assert set_outcome.response.status == 200
	assert set_outcome.response.body.contains('"ok":true')
	assert set_outcome.response.body.contains('"existsAfterSet":true')

	get_outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/get'
		req:         http.Request{
			method: .get
			url:    '/get'
			host:   'example.test'
		}
		remote_addr: '127.0.0.1'
		trace_id:    'trace_session_store_get'
		request_id:  'req_session_store_get'
	}) or { panic(err) }
	assert get_outcome.response.status == 200
	assert get_outcome.response.body.contains('"exists":true')
	assert get_outcome.response.body.contains('"status":"ready"')
	assert get_outcome.response.body.contains('"count":1')
}

fn test_inproc_vjsx_runtime_session_store_patch_updates_across_requests() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_session_store_patch_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'handler.mts')
	os.write_file(app_file, '
export default function handle(ctx) {
  const store = ctx.runtime.sessionStore("relay");
  if (ctx.path === "/seed") {
    return ctx.json({
      ok: store.set("srv:test", { count: 1, status: "ready" }, { ttlMs: 60000 })
    }, 200);
  }
  if (ctx.path === "/patch") {
    const value = store.patch(
      "srv:test",
      (current) => {
        const next = current && typeof current === "object" ? current : { count: 0, status: "new" };
        next.count = Number(next.count || 0) + 1;
        next.status = "patched";
        return next;
      },
      { count: 0, status: "new" },
      { ttlMs: 60000 }
    );
    return ctx.json({ value }, 200);
  }
  return ctx.json({
    value: store.get("srv:test", null)
  }, 200);
}
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
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
	_ := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/seed'
		req:         http.Request{
			method: .get
			url:    '/seed'
			host:   'example.test'
		}
		remote_addr: '127.0.0.1'
		trace_id:    'trace_session_store_patch_seed'
		request_id:  'req_session_store_patch_seed'
	}) or { panic(err) }

	patch_outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/patch'
		req:         http.Request{
			method: .get
			url:    '/patch'
			host:   'example.test'
		}
		remote_addr: '127.0.0.1'
		trace_id:    'trace_session_store_patch'
		request_id:  'req_session_store_patch'
	}) or { panic(err) }
	assert patch_outcome.response.status == 200
	assert patch_outcome.response.body.contains('"status":"patched"')
	assert patch_outcome.response.body.contains('"count":2')

	get_outcome := executor.dispatch_http(mut app, HttpLogicDispatchRequest{
		method:      'GET'
		path:        '/get'
		req:         http.Request{
			method: .get
			url:    '/get'
			host:   'example.test'
		}
		remote_addr: '127.0.0.1'
		trace_id:    'trace_session_store_patch_get'
		request_id:  'req_session_store_patch_get'
	}) or { panic(err) }
	assert get_outcome.response.status == 200
	assert get_outcome.response.body.contains('"status":"patched"')
	assert get_outcome.response.body.contains('"count":2')
}
