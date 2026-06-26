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
			mut app_ref := AppFacade(unsafe { nil })
			state.mu.@lock()
			if idx >= 0 && idx < state.hosts.len && state.hosts[idx].request_ctx.active {
				app_ref = state.hosts[idx].request_ctx.app
			}
			state.mu.unlock()
			if isnil(app_ref) {
				return ctx.js_string('')
			}
			mut app := app_ref
			path := if args.len > 0 { args[0].to_string().trim_space() } else { '' }
			return ctx.js_string(InProcVjsxHostApi.config_lookup(app.get_runtime_config_json(),
				path))
		})
	}
}
