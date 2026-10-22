module executor

import json2 as json
import vjsx

fn InProcVjsxWebSocketJs.install_session_store(ctx &vjsx.Context, mut runtime vjsx.Value) {
	factory := ctx.js_function(fn [ctx] (args []vjsx.Value) vjsx.Value {
		namespace := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
		mut store := ctx.js_object()
		store.set('namespace', namespace)
		get_fn := ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			key := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			fallback := if args.len > 1 { args[1].dup_value() } else { ctx.js_undefined() }
			if namespace == '' {
				return fallback
			}
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if host_api.is_undefined() || !host_api.is_object() || !host_api.has('sessionStore') {
				return fallback
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return fallback
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'get'
				key:       key
			}, escape_unicode: true, time_as_unix: true))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return fallback }
			defer {
				resp_raw.free()
			}
			resp := json.decode[InProcVjsxHostSessionStoreResponse](resp_raw.to_string()) or {
				return fallback
			}
			if !resp.ok || !resp.found || resp.value.trim_space() == '' {
				return fallback
			}
			fallback.free()
			return ctx.json_parse(resp.value)
		})
		defer { get_fn.free() }
		store.set('get', get_fn)
		set_fn := ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			if namespace == '' || args.len == 0 {
				return ctx.js_bool(false)
			}
			key := args[0].to_string().trim_space()
			value := if args.len > 1 { args[1].json_stringify() } else { 'null' }
			mut ttl_ms := i64(0)
			if args.len > 2 && args[2].is_object() && args[2].has('ttlMs') {
				ttl := args[2].get('ttlMs')
				defer { ttl.free() }
				ttl_ms = ttl.to_i64()
			}
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if host_api.is_undefined() || !host_api.is_object() || !host_api.has('sessionStore') {
				return ctx.js_bool(false)
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return ctx.js_bool(false)
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'set'
				key:       key
				value:     value
				ttl_ms:    ttl_ms
			}, escape_unicode: true, time_as_unix: true))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return ctx.js_bool(false) }
			defer {
				resp_raw.free()
			}
			resp := json.decode[InProcVjsxHostSessionStoreResponse](resp_raw.to_string()) or {
				return ctx.js_bool(false)
			}
			return ctx.js_bool(resp.ok)
		})
		defer { set_fn.free() }
		store.set('set', set_fn)
		delete_fn := ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			key := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if namespace == '' || host_api.is_undefined() || !host_api.is_object()
				|| !host_api.has('sessionStore') {
				return ctx.js_bool(false)
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return ctx.js_bool(false)
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'delete'
				key:       key
			}, escape_unicode: true, time_as_unix: true))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return ctx.js_bool(false) }
			defer {
				resp_raw.free()
			}
			resp := json.decode[InProcVjsxHostSessionStoreResponse](resp_raw.to_string()) or {
				return ctx.js_bool(false)
			}
			return ctx.js_bool(resp.ok)
		})
		defer { delete_fn.free() }
		store.set('delete', delete_fn)
		exists_fn := ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			key := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if namespace == '' || host_api.is_undefined() || !host_api.is_object()
				|| !host_api.has('sessionStore') {
				return ctx.js_bool(false)
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return ctx.js_bool(false)
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'exists'
				key:       key
			}, escape_unicode: true, time_as_unix: true))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return ctx.js_bool(false) }
			defer {
				resp_raw.free()
			}
			resp := json.decode[InProcVjsxHostSessionStoreResponse](resp_raw.to_string()) or {
				return ctx.js_bool(false)
			}
			return ctx.js_bool(resp.ok && resp.found)
		})
		defer { exists_fn.free() }
		store.set('exists', exists_fn)
		keys_fn := ctx.js_function(fn [ctx, namespace] (args []vjsx.Value) vjsx.Value {
			fallback := if args.len > 0 { args[0].dup_value() } else { ctx.js_array() }
			host_api := ctx.js_global('vhttpdHost')
			defer {
				host_api.free()
			}
			if namespace == '' || host_api.is_undefined() || !host_api.is_object()
				|| !host_api.has('sessionStore') {
				return fallback
			}
			host_fn := host_api.get('sessionStore')
			defer {
				host_fn.free()
			}
			if !host_fn.is_function() {
				return fallback
			}
			payload := ctx.js_string(json.encode(InProcVjsxHostSessionStoreRequest{
				namespace: namespace
				op:        'keys'
			}, escape_unicode: true, time_as_unix: true))
			defer {
				payload.free()
			}
			resp_raw := ctx.call(host_fn, payload) or { return fallback }
			defer {
				resp_raw.free()
			}
			resp := json.decode[InProcVjsxHostSessionStoreResponse](resp_raw.to_string()) or {
				return fallback
			}
			if !resp.ok {
				return fallback
			}
			fallback.free()
			if resp.keys.len > 0 {
				return ctx.json_parse(json.encode(resp.keys,
					escape_unicode: true
					time_as_unix:   true
				))
			}
			if resp.value.trim_space() != '' {
				return ctx.json_parse(resp.value)
			}
			return ctx.js_array()
		})
		defer { keys_fn.free() }
		store.set('keys', keys_fn)
		return store
	})
	defer { factory.free() }
	runtime.set('sessionStore', factory)
}
