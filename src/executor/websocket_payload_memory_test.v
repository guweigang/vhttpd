module executor

import vjsx
import upstream.transport
import os
import time

fn websocket_payload_batch(ctx &vjsx.Context, count int) {
	mut app := NoOpAppFacade{}
	for i in 0 .. count {
		input := InProcVjsxWebSocketCallbackInput{
			runtime_meta: InProcVjsxRuntimeMeta{ request_id: 'request-${i}', path: '/ws' }
			frame:        transport.WorkerWebSocketFrame{ event: 'message', data: 'payload-${i}' }
		}
		runtime, frame := InProcVjsxWebSocketCallback.build_payload(ctx, input, '{}', mut app)
		runtime.free()
		frame.free()
	}
}

fn test_websocket_payload_does_not_allocate_unused_native_callback_facades() {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	mut ctx := session.context()
	InProcVjsxHostApi.install_http_facade(mut ctx) or { panic(err) }
	websocket_payload_batch(ctx, 16)
	session.runtime().run_gc()
	gc_collect()
	before_native := gc_memory_use()
	before_js := session.memory_usage()
	websocket_payload_batch(ctx, 1024)
	session.runtime().run_gc()
	gc_collect()
	after_native := gc_memory_use()
	after_js := session.memory_usage()
	if gc_is_enabled() {
		assert after_native <= before_native + 1024 * 1024, 'WebSocket payloads retained unused native callbacks: ${before_native} -> ${after_native}'
	}
	assert after_js.object_count <= before_js.object_count + 8
}

fn test_websocket_payload_returns_the_runtime_owned_by_its_frame() {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	mut ctx := session.context()
	InProcVjsxHostApi.install_http_facade(mut ctx) or { panic(err) }
	mut app := NoOpAppFacade{}
	runtime, frame := InProcVjsxWebSocketCallback.build_payload(ctx,
		InProcVjsxWebSocketCallbackInput{ runtime_meta: InProcVjsxRuntimeMeta{ request_id: 'owned' } }, '{}', mut app)
	defer {
		runtime.free()
		frame.free()
	}
	global := ctx.js_global()
	global.set('payloadRuntime', runtime)
	global.set('payloadFrame', frame)
	global.free()
	result := ctx.eval('payloadRuntime === payloadFrame.runtime && payloadRuntime.requestId === "owned"') or { panic(err) }
	defer { result.free() }
	assert result.to_string() == 'true'
}

fn websocket_query_batch(exec InProcVjsxExecutor, count int) {
	mut app := NoOpAppFacade{}
	lane := exec.lane_snapshot()[0]
	for i in 0 .. count {
		frame := transport.WorkerWebSocketFrame{ event: 'open', path: '/query', request_id: 'query-${i}' }
		actor := exec.resolve_websocket_actor_on_lane(mut app, frame, lane) or { panic(err) }
		affinity := exec.resolve_websocket_affinity_on_lane(mut app, frame, lane) or { panic(err) }
		assert actor.key == '/query'
		assert affinity.key == '/query'
	}
}

fn test_websocket_routing_queries_do_not_retain_per_query_native_callbacks() {
	root := os.join_path(os.temp_dir(), 'vhttpd-ws-query-memory-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	entry := os.join_path(root, 'app.js')
	os.write_file(entry, 'globalThis.__vhttpd_handle = () => "ready"; globalThis.__vhttpd_websocket_actor_handle = frame => ({key:frame.path}); globalThis.__vhttpd_websocket_affinity_handle = frame => ({key:frame.path});') or { panic(err) }
	exec := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		app_entry:         entry
		module_root:       root
		signature_root:    root
		signature_include: ['app.js']
		build_root:        os.join_path(root, 'cache')
		runtime_profile:   'script'
		thread_count:      1
	})
	defer { exec.close() }
	websocket_query_batch(exec, 16)
	session := exec.state.hosts[0].session_handle() or { panic('missing query session') }
	session.runtime().run_gc()
	gc_collect()
	before := gc_memory_use()
	before_js := session.memory_usage()
	websocket_query_batch(exec, 1024)
	session.runtime().run_gc()
	gc_collect()
	after := gc_memory_use()
	assert !gc_is_enabled() || after <= before + 1024 * 1024, 'Routing queries retained native callbacks: ${before} -> ${after}'
	assert session.memory_usage().object_count <= before_js.object_count + 8
}
