module executor

import os
import upstream.transport
import vjsx

struct WsJsOwnerHost {
	NoOpAppFacade
}

fn (_ WsJsOwnerHost) get_runtime_plan_json() string { return '{"value":42}' }

fn (mut _ WsJsOwnerHost) execute_websocket_dispatch_commands_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	if commands.len > 0 && commands[0].event == 'close' {
		return transport.WorkerWebSocketDispatchCommandsResult{ has_close: true, close_frame: transport.WorkerWebSocketFrame{ code: 1001, reason: 'done', target_id: 'target' } }
	}
	return transport.WorkerWebSocketDispatchCommandsResult{}
}

fn ws_js_owner_eval(ctx &vjsx.Context, code string) {
	result := ctx.eval(code) or { panic(err) }
	result.free()
}

fn ws_js_owner_runtime(ctx &vjsx.Context, mut host WsJsOwnerHost, minimal bool) vjsx.Value {
	old := os.getenv_opt('VHTTPD_VJSX_WS_MINIMAL_RUNTIME')
	os.setenv('VHTTPD_VJSX_WS_MINIMAL_RUNTIME', if minimal { '1' } else { '0' }, true)
	defer {
		if value := old {
			os.setenv('VHTTPD_VJSX_WS_MINIMAL_RUNTIME', value, true)
		} else {
			os.unsetenv('VHTTPD_VJSX_WS_MINIMAL_RUNTIME')
		}
	}
	return InProcVjsxWebSocketJs.runtime(ctx, InProcVjsxRuntimeMeta{
		request_id:     'request'
		trace_id:       'trace'
		request_server: {
			'name': 'server'
		}
	}, '{"value":42}', mut host)
}

fn ws_js_owner_heap(code string) {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	ctx := session.context()
	mut host := &WsJsOwnerHost{}
	runtime := ws_js_owner_runtime(ctx, mut host, false)
	global := ctx.js_global()
	global.set('runtime', runtime)
	runtime.free()
	global.free()
	ws_js_owner_eval(ctx, 'globalThis.exercise = function(n) { for (let i=0;i<n;i++) { ${code} } }; exercise(2);')
	session.runtime().run_gc()
	before := session.memory_usage()
	ws_js_owner_eval(ctx, 'exercise(200);')
	session.runtime().run_gc()
	after := session.memory_usage()
	assert after.object_count <= before.object_count + 8
	assert after.string_count <= before.string_count + 8
}

fn test_websocket_runtime_publication_releases_temporary_objects_and_callbacks() {
	for minimal in [false, true] {
		mut session := vjsx.new_runtime_session()
		defer { session.close() }
		ctx := session.context()
		mut host := &WsJsOwnerHost{}
		for _ in 0 .. 2 {
			value := ws_js_owner_runtime(ctx, mut host, minimal)
			value.free()
		}
		session.runtime().run_gc()
		before := session.memory_usage()
		for _ in 0 .. 200 {
			value := ws_js_owner_runtime(ctx, mut host, minimal)
			value.free()
		}
		session.runtime().run_gc()
		after := session.memory_usage()
		assert after.object_count <= before.object_count + 8
		assert after.string_count <= before.string_count + 8
	}
}

fn test_websocket_frame_publication_releases_temporary_nested_maps() {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	ctx := session.context()
	runtime := ctx.js_object()
	defer { runtime.free() }
	frame := transport.WorkerWebSocketFrame{
		query:    {
			'q': 'value'
		}
		headers:  {
			'x-test': 'value'
		}
		metadata: {
			'key': 'value'
		}
	}
	for _ in 0 .. 2 {
		value := InProcVjsxWebSocketJs.frame(ctx, frame, runtime)
		value.free()
	}
	session.runtime().run_gc()
	before := session.memory_usage()
	for _ in 0 .. 200 {
		value := InProcVjsxWebSocketJs.frame(ctx, frame, runtime)
		value.free()
	}
	session.runtime().run_gc()
	after := session.memory_usage()
	assert after.object_count <= before.object_count + 8
	assert after.string_count <= before.string_count + 8
}

fn test_websocket_config_success_releases_unused_fallback() {
	ws_js_owner_heap('if(runtime.config("value", {unused:i}) !== "42") throw Error("config");')
}

fn test_websocket_getconfig_success_releases_unused_fallback() {
	ws_js_owner_heap('if(runtime.getConfig("value", {unused:i}) !== 42) throw Error("getConfig");')
}

fn test_websocket_plan_success_releases_unused_fallback() {
	ws_js_owner_heap('if(runtime.plan("value", {unused:i}) !== "42") throw Error("plan");')
}

fn test_websocket_getplan_success_releases_unused_fallback() {
	ws_js_owner_heap('if(runtime.getPlan("value", {unused:i}) !== 42) throw Error("getPlan");')
}

fn test_websocket_dispatch_success_releases_unused_fallback() {
	ws_js_owner_heap('if(!runtime.websocketDispatch([{event:"send"}], {unused:i}).ok) throw Error("dispatch");')
}

fn test_websocket_bridge_published_results_and_fallbacks_remain_live() {
	ws_js_owner_heap('
		const fallback = {sentinel:true};
		for (const name of ["config","getConfig","plan","getPlan"]) {
			if(runtime[name]("missing", fallback) !== fallback) throw Error("fallback");
		}
		if(runtime.request.server.name !== "server" || !runtime.capabilities.websocketDispatch) throw Error("metadata");
		if(typeof runtime.now() !== "number") throw Error("callback lifetime");
		if(runtime.websocketDispatch(null, fallback) !== fallback) throw Error("dispatch fallback");
		const close = runtime.websocketDispatch({event:"close"}, fallback);
		if(!close.has_close || close.close_code !== 1001 || close.close_reason !== "done" || close.close_target_id !== "target") throw Error("close result");
		if(!fallback.sentinel) throw Error("borrowed fallback");
	')
}
