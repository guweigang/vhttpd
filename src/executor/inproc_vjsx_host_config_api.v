module executor

import vjsx
import x.json2

fn InProcVjsxHostApi.config_lookup(raw_json string, path string) string {
	if raw_json.trim_space() == '' {
		return ''
	}
	if path.trim_space() == '' {
		return raw_json
	}
	parsed := json2.decode[json2.Any](raw_json) or { return '' }
	mut current := parsed
	for raw_part in path.split('.') {
		part := raw_part.trim_space()
		if part == '' {
			continue
		}
		root := current.as_map()
		if part !in root {
			return ''
		}
		current = root[part] or { return '' }
	}
	return current.json_str()
}

fn InProcVjsxHostApi.config_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			access := state.request_host(idx, .request_only) or { return ctx.js_string('') }
			mut app := access.host
			path := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			return ctx.js_string(InProcVjsxHostApi.config_lookup(app.get_runtime_config_json(),
				path))
		})
	}
}
