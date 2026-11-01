module executor

import vjsx

// Only trusted application code calls this after authenticating an account.
// No client header or event property is treated as an authenticated identity.
pub interface TakeoverFacade {
	EmbeddedHost
mut:
	vjsx_takeover_request(string) !string
}

fn InProcVjsxHostApi.takeover_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			if args.len != 1 {
				return ctx.js_throw(ctx.js_error(message: 'takeover_invalid_request'))
			}
			access := state.request_host(idx, .request_only) or { return ctx.js_throw(ctx.js_error(
				message: 'takeover_request_unavailable'
			)) }
			mut host := access.host
			if mut host is TakeoverFacade {
				result := host.vjsx_takeover_request(args[0].to_string()) or { return ctx.js_throw(ctx.js_error(
					message: 'takeover_result_unknown'
				)) }
				return ctx.js_string(result)
			}
			return ctx.js_string('{"handled":false}')
		})
	}
}
