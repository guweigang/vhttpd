module executor

import vjsx

fn store_owner_eval(ctx &vjsx.Context, code string) {
	result := ctx.eval(code) or { panic(err) }
	result.free()
}

fn store_owner_session() &vjsx.RuntimeSession {
	mut session := vjsx.new_runtime_session()
	ctx := session.context()
	mut api := ctx.js_object()
	InProcVjsxWebSocketJs.install_session_store(ctx, mut api)
	global := ctx.js_global()
	global.set('runtime', api)
	api.free()
	global.free()
	store_owner_eval(ctx, 'globalThis.vhttpdHost = {sessionStore: () => JSON.stringify({ok:true, found:true, value:"42", keys:["key"]})}; globalThis.store = runtime.sessionStore("ns");')
	return &session
}

fn store_owner_bounded_heap(code string) {
	mut session := store_owner_session()
	defer { session.close() }
	ctx := session.context()
	store_owner_eval(ctx, 'globalThis.exercise = function(n) { for (let i=0; i<n; i++) { ${code} } }; exercise(2);')
	session.runtime().run_gc()
	before := session.memory_usage()
	store_owner_eval(ctx, 'exercise(200);')
	session.runtime().run_gc()
	after := session.memory_usage()
	assert after.object_count <= before.object_count + 8
	assert after.string_count <= before.string_count + 8
}

fn test_session_store_factory_releases_temporary_method_references() {
	store_owner_bounded_heap('runtime.sessionStore("temporary");')
}

fn test_session_store_successful_get_releases_unused_object_fallback() {
	store_owner_bounded_heap('if (store.get("key", {unused:i}) !== 42) throw Error("get");')
}

fn test_session_store_successful_keys_releases_default_array_fallback() {
	store_owner_bounded_heap('if (store.keys()[0] !== "key") throw Error("keys");')
}

fn test_session_store_successful_keys_releases_supplied_fallback() {
	store_owner_bounded_heap('if (store.keys({unused:i})[0] !== "key") throw Error("keys");')
}

fn test_session_store_set_releases_owned_ttl_property_value() {
	store_owner_bounded_heap('if (!store.set("key", 42, {ttlMs:{valueOf(){return 1;}}})) throw Error("set");')
}

fn test_session_store_fallback_and_success_results_keep_their_ownership() {
	mut session := store_owner_session()
	defer { session.close() }
	store_owner_eval(session.context(), '
		const fallback = {sentinel:true};
		for (const mode of ["missing", "throw", "invalid", "notok", "notfound"]) {
			vhttpdHost.sessionStore = () => {
				if (mode === "throw") throw Error("host");
				if (mode === "invalid") return "invalid";
				return JSON.stringify({ok:mode !== "notok", found:false});
			};
			if (mode === "missing") delete vhttpdHost.sessionStore;
			if (store.get("key", fallback) !== fallback) throw Error("fallback identity");
			if (!fallback.sentinel) throw Error("fallback lifetime");
		}
		vhttpdHost.sessionStore = () => JSON.stringify({ok:false});
		if (store.keys(fallback) !== fallback) throw Error("keys fallback");
		if (!Array.isArray(store.keys())) throw Error("keys default");
		if (runtime.sessionStore("").get("key", fallback) !== fallback) throw Error("namespace fallback");
		for (const result of [{ok:true, keys:["one"]}, {ok:true, value:"[1,2]"}, {ok:true}]) {
			vhttpdHost.sessionStore = () => JSON.stringify(result);
			if (!Array.isArray(store.keys(fallback))) throw Error("keys result");
		}
		if (!fallback.sentinel) throw Error("borrowed fallback was freed");
	')
}
