module executor

import json
import vjsx

fn InProcVjsxWebSocketJs.install_websocket_dispatch(ctx &vjsx.Context, mut runtime vjsx.Value, mut app AppFacade) {
	runtime.set('websocketDispatch', ctx.js_function(fn [ctx, mut app] (args []vjsx.Value) vjsx.Value {
		fallback := if args.len > 1 { args[1].dup_value() } else { ctx.js_undefined() }
		if args.len == 0 {
			return fallback
		}
		raw := args[0].json_stringify().trim_space()
		if raw == '' || raw == 'undefined' || raw == 'null' {
			return fallback
		}
		req_raw := if raw.starts_with('[') {
			'{"commands":${raw}}'
		} else {
			decoded := json.decode(InProcVjsxHostWebSocketDispatchRequest, raw) or {
				InProcVjsxHostWebSocketDispatchRequest{}
			}
			if decoded.commands.len > 0 {
				raw
			} else {
				'{"commands":[${raw}]}'
			}
		}
		req := json.decode(InProcVjsxHostWebSocketDispatchRequest, req_raw) or { return fallback }
		result := app.execute_websocket_dispatch_commands_result(req.commands)
		response := if result.has_close {
			InProcVjsxHostWebSocketDispatchResponse{
				ok:              true
				has_close:       true
				close_code:      result.close_frame.code
				close_reason:    result.close_frame.reason
				close_target_id: if result.close_frame.target_id != '' {
					result.close_frame.target_id
				} else {
					result.close_frame.id
				}
				failures:        result.failures
			}
		} else {
			InProcVjsxHostWebSocketDispatchResponse{
				ok:       true
				failures: result.failures
			}
		}
		return ctx.json_parse(json.encode(response))
	}))
}
