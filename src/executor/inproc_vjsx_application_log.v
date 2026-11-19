module executor

import application_logs
import json2 as json
import vjsx

// Called before warmup. Each executor retains its own immutable native scope;
// async console callbacks never borrow another request's ambient identity.
pub fn (e InProcVjsxExecutor) set_application_log_scope(scope application_logs.Scope) {
	mut state := e.state
	state.mu.@lock()
	state.application_log_scope = scope
	state.mu.unlock()
}

fn (mut state VjsxExecutorState) write_application_log(idx int, level string, message string, fields map[string]string) {
	state.mu.@lock()
	scope := state.application_log_scope
	lane := if idx >= 0 && idx < state.lanes.len { state.lanes[idx].id } else { '' }
	state.mu.unlock()
	mut store := application_logs.shared()
	store.append(scope, application_logs.Record{
		level:if level in ['debug','info','warn','error'] { level } else { 'info' }
		source:'console'
		lane_id:lane
		message:message
		request_id:bounded_log_identity(fields['requestId'])
		trace_id:bounded_log_identity(fields['traceId'])
	})
}

fn bounded_log_identity(value string) string {
	return if value.len > 256 { value[..256].clone() } else { value.clone() }
}

fn InProcVjsxHostApi.log_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			if args.len < 2 { return ctx.js_undefined() }
			fields := if args.len > 2 { json.decode[map[string]string](args[2].json_stringify()) or { map[string]string{} } } else { map[string]string{} }
			state.write_application_log(idx,args[0].to_string(),args[1].to_string(),fields)
			return ctx.js_undefined()
		})
	}
}

fn InProcVjsxHostApi.install_application_console(ctx &vjsx.Context, mut state VjsxExecutorState, idx int) {
	console := ctx.js_global('console')
	defer { console.free() }
	for name in ['log','info','debug','warn','error'] {
		level := if name == 'log' { 'info' } else { name }
		callback := ctx.js_function(fn [ctx, mut state, idx, level] (args []vjsx.Value) vjsx.Value {
			state.write_application_log(idx,level,InProcVjsxWebSocketJs.log_args(args),map[string]string{})
			return ctx.js_undefined()
		})
		console.set(name,callback)
		callback.free()
	}
}
