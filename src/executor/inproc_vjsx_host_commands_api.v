module executor

import json2 as json
import upstream.transport
import vjsx

fn InProcVjsxHostApi.commands_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			if args.len == 0 { return ctx.js_throw(ctx.js_error(message: 'commands_missing')) }
			raw := if args[0].is_string() { args[0].to_string() } else { args[0].json_stringify() }
			commands := json.decode[[]transport.WorkerWebSocketUpstreamCommand](raw) or {
				return ctx.js_throw(ctx.js_error(message: 'invalid_commands'))
			}
			access := state.request_host(idx, .request_only) or {
				return ctx.js_throw(ctx.js_error(message: 'commands_host_unavailable'))
			}
			mut host := access.host
			failure := host.run_command_envelopes(access.context.request_id, DispatchContext{}, commands)
			if failure != '' { return ctx.js_throw(ctx.js_error(message: failure)) }
			return ctx.js_undefined()
		})
	}
}
