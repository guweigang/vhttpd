module executor

import vjsx

// Optional trusted host capability; reduced/test hosts fail closed.
pub interface FeishuCreationFacade {
	EmbeddedHost
mut:
	issue_feishu_stream_creation(stream_id string, app_name string, message_id string) !string
}

fn InProcVjsxHostApi.feishu_creation_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			if args.len == 0 { return ctx.js_string('') }
			access := state.request_host(idx, .request_only) or { return ctx.js_string('') }
			mut host := access.host
			if mut host is FeishuCreationFacade {
				generation := host.issue_feishu_stream_creation(args[0].to_string(), if args.len > 1 {
					args[1].to_string()
				} else {
					''
				}, if args.len > 2 { args[2].to_string() } else { '' }) or { return ctx.js_string('') }
				return ctx.js_string(generation)
			}
			return ctx.js_string('')
		})
	}
}
