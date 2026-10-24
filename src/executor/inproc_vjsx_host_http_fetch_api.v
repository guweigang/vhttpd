module executor

import vjsx

fn InProcVjsxHostApi.http_fetch_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		// Retain the installed native transport, including its host-async queue.
		// AbortSignal stays a JS object; it must not cross a JSON boundary.
		fetch := ctx.js_global('fetch')
		ctx.register_host_cleanup(fn [fetch] () { fetch.free() })
		return ctx.js_function(fn [ctx, fetch, mut state, idx] (args []vjsx.Value) vjsx.Value {
			_ = idx
			if args.len < 2 {
				return ctx.js_throw(ctx.js_error(
					message: 'invalid_fetch_request'
					name:    'TypeError'
				))
			}
			mut enable_network := false
			state.mu.@lock()
			enable_network = state.facade.config.enable_network
			state.mu.unlock()
			if !enable_network {
				return ctx.js_throw(ctx.js_error(message: 'network_disabled'))
			}
			return ctx.call(fetch, args[0], args[1]) or {
				return ctx.js_throw(ctx.js_error(message: err.msg()))
			}
		})
	}
}
