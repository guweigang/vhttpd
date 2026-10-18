module executor

import json2 as json
import state_store
import vjsx

fn InProcVjsxHostApi.session_store_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	_ = idx
	return fn [mut state] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state] (args []vjsx.Value) vjsx.Value {
			if args.len == 0 {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'missing_session_store_request'
				}, escape_unicode: true, time_as_unix: true))
			}
			raw := args[0].to_string().trim_space()
			if raw == '' {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'missing_session_store_request'
				}, escape_unicode: true, time_as_unix: true))
			}
			req := json.decode[InProcVjsxHostSessionStoreRequest](raw) or {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'invalid_session_store_request'
				}, escape_unicode: true, time_as_unix: true))
			}
			namespace := req.namespace.trim_space()
			key := req.key.trim_space()
			if namespace == '' {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'session_store_namespace_missing'
				}, escape_unicode: true, time_as_unix: true))
			}
			if key == '' && req.op != 'keys' {
				return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
					error: 'session_store_key_missing'
				}, escape_unicode: true, time_as_unix: true))
			}
			full_key := '${namespace}:${key}'
			return match req.op {
				'get' {
					value := state.session_store.get(full_key) or {
						return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
							ok:    true
							found: false
						}, escape_unicode: true, time_as_unix: true))
					}
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok:    true
						found: true
						value: value
					}, escape_unicode: true, time_as_unix: true))
				}
				'set' {
					ttl := state_store.ttl_from_milliseconds(req.ttl_ms) or {
						return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
							error: err.msg()
						}, escape_unicode: true, time_as_unix: true))
					}
					state.session_store.set_with_ttl(full_key, req.value, ttl) or {
						return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
							error: err.msg()
						}, escape_unicode: true, time_as_unix: true))
					}
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok: true
					}, escape_unicode: true, time_as_unix: true))
				}
				'patch' {
					mut swapped := false
					if req.delete_value {
						swapped = state.session_store.compare_and_swap_delete(full_key,
							req.expected_found, req.expected_value) or {
							return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
								error: err.msg()
							}, escape_unicode: true, time_as_unix: true))
						}
					} else {
						ttl := state_store.ttl_from_milliseconds(req.ttl_ms) or {
							return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
								error: err.msg()
							}, escape_unicode: true, time_as_unix: true))
						}
						swapped = state.session_store.compare_and_swap_set_with_ttl(full_key,
							req.expected_found, req.expected_value, req.value,
							ttl) or {
							return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
								error: err.msg()
							}, escape_unicode: true, time_as_unix: true))
						}
					}
					if !swapped {
						return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
							ok:       false
							conflict: true
						}, escape_unicode: true, time_as_unix: true))
					}
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok: true
					}, escape_unicode: true, time_as_unix: true))
				}
				'delete' {
					state.session_store.delete(full_key) or {
						return ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
							error: err.msg()
						}, escape_unicode: true, time_as_unix: true))
					}
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok: true
					}, escape_unicode: true, time_as_unix: true))
				}
				'exists' {
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok:    true
						found: state.session_store.exists(full_key)
					}, escape_unicode: true, time_as_unix: true))
				}
				'keys' {
					prefix := '${namespace}:'
					keys :=
						state.session_store.keys().filter(it.starts_with(prefix)).map(it[prefix.len..])
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						ok:    true
						found: keys.len > 0
						keys:  keys
					}, escape_unicode: true, time_as_unix: true))
				}
				else {
					ctx.js_string(json.encode(InProcVjsxHostSessionStoreResponse{
						error: 'unsupported_session_store_op:${req.op}'
					}, escape_unicode: true, time_as_unix: true))
				}
			}
		})
	}
}
