module executor

import vjsx
import configcache

fn InProcVjsxHostApi.config_lookup(raw_json string, path string) string {
	return configcache.resolve(raw_json, path)
}

fn InProcVjsxHostApi.config_builder(mut state VjsxExecutorState, idx int, mut cache configcache.Cache) vjsx.HostValueBuilder {
	return fn [mut state, idx, mut cache] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx, mut cache] (args []vjsx.Value) vjsx.Value {
			access := state.request_host(idx, .request_only) or { return ctx.js_string('') }
			mut app := access.host
			path := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			return ctx.js_string(cache.lookup(app.get_runtime_config_json(),
				path))
		})
	}
}
