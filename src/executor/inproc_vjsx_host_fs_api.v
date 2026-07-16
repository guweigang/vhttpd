module executor

import os
import vjsx

fn InProcVjsxHostApi.read_text_file_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			_ = idx
			if args.len == 0 {
				return ctx.js_string('')
			}
			path := args[0].to_string().trim_space()
			if path == '' {
				return ctx.js_string('')
			}
			mut enable_fs := false
			state.mu.@lock()
			enable_fs = state.facade.config.enable_fs
			state.mu.unlock()
			if !enable_fs {
				return ctx.js_string('')
			}
			content := os.read_file(path) or {
				resolved := os.real_path(path)
				if resolved != '' && resolved != path {
					return ctx.js_string(os.read_file(resolved) or { '' })
				}
				return ctx.js_string('')
			}
			return ctx.js_string(content)
		})
	}
}

fn InProcVjsxHostApi.find_codex_session_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			_ = idx
			if args.len == 0 {
				return ctx.js_string('')
			}
			thread_id := args[0].to_string().trim_space()
			if thread_id == '' {
				return ctx.js_string('')
			}
			mut enable_fs := false
			state.mu.@lock()
			enable_fs = state.facade.config.enable_fs
			state.mu.unlock()
			if !enable_fs {
				return ctx.js_string('')
			}
			return ctx.js_string(CodexSessionLocator.find(thread_id))
		})
	}
}
