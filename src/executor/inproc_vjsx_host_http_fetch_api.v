module executor

import json
import net.http
import vjsx

fn InProcVjsxHostApi.http_fetch_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			_ = idx
			if args.len == 0 {
				return ctx.js_string('')
			}
			raw := args[0].to_string().trim_space()
			if raw == '' {
				return ctx.js_string('')
			}
			mut enable_network := false
			state.mu.@lock()
			enable_network = state.facade.config.enable_network
			state.mu.unlock()
			if !enable_network {
				return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
					ok:    false
					error: 'network_disabled'
				}))
			}
			parsed := json.decode(InProcVjsxHostHttpFetchRequest, raw) or {
				return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
					ok:    false
					error: 'invalid_fetch_request'
				}))
			}
			url := parsed.url.trim_space()
			if url == '' {
				return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
					ok:    false
					error: 'missing_url'
				}))
			}
			method_raw := parsed.method.trim_space()
			method := match method_raw.to_upper() {
				'POST' { http.Method.post }
				'PUT' { http.Method.put }
				'PATCH' { http.Method.patch }
				'DELETE' { http.Method.delete }
				'HEAD' { http.Method.head }
				'OPTIONS' { http.Method.options }
				else { http.Method.get }
			}

			body := parsed.body
			mut header := http.new_header()
			for name, value in parsed.headers {
				header.add_custom(name, value) or {} // safe to ignore: response already committed
			}
			resp := http.fetch(http.FetchConfig{
				url:    url
				method: method
				data:   body
				header: header
			}) or {
				return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
					ok:    false
					error: err.msg()
				}))
			}
			mut response_headers := map[string]string{}
			for key in resp.header.keys() {
				response_headers[key] = resp.header.get_custom(key) or { '' }
			}
			return ctx.js_string(json.encode(InProcVjsxHostHttpFetchResponse{
				ok:      true
				status:  resp.status_code
				body:    resp.body
				headers: response_headers
			}))
		})
	}
}
