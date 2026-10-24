module executor

import os
import vjsx

fn binding_owner_eval(ctx &vjsx.Context, source string) {
	result := ctx.eval(source) or { panic(err) }
	result.free()
}

fn binding_owner_session() &vjsx.RuntimeSession {
	mut session := vjsx.new_runtime_session()
	path := os.getenv('VHTTPD_TEST_FACADE_SOURCE')
	source := if path != '' {
		os.read_file(path) or { panic(err) }
	} else {
		inproc_vjsx_http_facade_source.to_string()
	}
	binding_owner_eval(session.context(), source)
	return &session
}

fn binding_owner_bounded(kind string) {
	mut session := binding_owner_session()
	defer { session.close() }
	ctx := session.context()
	binding_owner_eval(ctx, 'globalThis.__vhttpd_bind_handlers({${kind}: function(frame){return frame.value;}}); globalThis.exercise = function(n) {for(let i=0;i<n;i++){__vhttpd_register_exports(undefined); if(globalThis.__vhttpd_${kind}_handle({value:i}) !== i) throw Error("dispatch");}}; exercise(2);')
	session.runtime().run_gc()
	before := session.memory_usage()
	binding_owner_eval(ctx, 'exercise(200);')
	session.runtime().run_gc()
	after := session.memory_usage()
	assert after.object_count <= before.object_count + 8
	assert after.string_count <= before.string_count + 8
}

fn test_websocket_fallback_registration_does_not_retain_wrapper_chain() {
	binding_owner_bounded('websocket')
}

fn test_upstream_fallback_registration_does_not_retain_wrapper_chain() {
	binding_owner_bounded('websocket_upstream')
}

fn binding_owner_identity(kind string) {
	mut session := binding_owner_session()
	defer { session.close() }
	result := session.context().eval('
		let logged = 0;
		globalThis.console = {error(){logged++;}};
		const failure = {message:"owned failure"};
		__vhttpd_bind_handlers({${kind}:function(){throw failure;}});
		const first = globalThis.__vhttpd_${kind}_handle;
		for(let i=0;i<40;i++) {
			__vhttpd_register_exports(i%2 ? undefined : {http(){return "http";}});
		}
		const same = globalThis.__vhttpd_${kind}_handle === first;
		let preserved = false;
		try { globalThis.__vhttpd_${kind}_handle({}); }
		catch(error) { preserved = error === failure; }
		({same, logged, preserved});
	') or { panic(err) }
	defer { result.free() }
	same := result.get('same')
	logged := result.get('logged')
	preserved := result.get('preserved')
	defer {
		same.free()
		logged.free()
		preserved.free()
	}
	assert same.to_string() == 'true'
	assert logged.to_int() == 1
	assert preserved.to_string() == 'true'
}

fn test_websocket_fallback_keeps_wrapper_identity_and_single_failure_log() {
	binding_owner_identity('websocket')
}

fn test_upstream_fallback_keeps_wrapper_identity_and_single_failure_log() {
	binding_owner_identity('websocket_upstream')
}

fn test_explicit_handler_replacement_releases_old_wrappers_and_publishes_new_owners() {
	mut session := binding_owner_session()
	defer { session.close() }
	ctx := session.context()
	binding_owner_eval(ctx, 'globalThis.replace = function(n){for(let i=0;i<n;i++){__vhttpd_register_exports({websocket(){return i;}, websocket_upstream(){return i;}}); if(__vhttpd_websocket_handle({}) !== i || __vhttpd_websocket_upstream_handle({}) !== i) throw Error("replacement");}}; replace(2);')
	session.runtime().run_gc()
	before := session.memory_usage()
	binding_owner_eval(ctx, 'replace(200);')
	session.runtime().run_gc()
	after := session.memory_usage()
	assert after.object_count <= before.object_count + 8
}

fn test_rebound_handlers_preserve_receiver_arguments_and_promise_result() {
	mut session := binding_owner_session()
	defer { session.close() }
	ctx := session.context()
	result := ctx.eval('
		const target = {prefix:"bound", handleWebSocket(frame){return Promise.resolve(this.prefix + frame.value);}};
		__vhttpd_bind_handlers({default:target});
		for(let i=0;i<20;i++) __vhttpd_register_exports({});
		__vhttpd_invoke_websocket_handle({value:"-result"});
	') or { panic(err) }
	defer { result.free() }
	resolved := session.resolve_value(result) or { panic(err) }
	defer { resolved.free() }
	assert resolved.to_string() == 'bound-result'
}
