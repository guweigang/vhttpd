module executor

import json
import vjsx

fn InProcVjsxHostApi.bridge_dispatch_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			if args.len == 0 {
				return ctx.js_string('')
			}
			raw := args[0].to_string().trim_space()
			if raw == '' {
				return ctx.js_string('')
			}
			req := json.decode(InProcVjsxHostBridgeDispatchRequest, raw) or {
				return ctx.js_string(json.encode(FeishuCardBridgeResult{
					error: 'invalid_bridge_dispatch_request'
				}))
			}
			mut app_ref := AppFacade(unsafe { nil })
			mut request_trace_id := ''
			state.mu.@lock()
			if idx >= 0 && idx < state.hosts.len && state.hosts[idx].request_ctx.active {
				app_ref = state.hosts[idx].request_ctx.app
				request_trace_id = state.hosts[idx].request_ctx.trace_id
			}
			state.mu.unlock()
			if isnil(app_ref) {
				return ctx.js_string(json.encode(FeishuCardBridgeResult{
					error: 'bridge_dispatch_app_missing'
				}))
			}
			mut app := app_ref
			summary := FeishuRuntimeEventSummary.from_payload(req.payload)
			trace_id := if req.trace_id.trim_space() != '' { req.trace_id } else { request_trace_id }
			result := app.provider_bridge_dispatch_callback('feishu', req.app, trace_id, FeishuRuntimeEventSummary{
				event_id:        summary.event_id
				event_kind:      if summary.event_kind != '' { summary.event_kind } else { 'action' }
				event_type:      if req.event_type.trim_space() != '' {
					req.event_type
				} else {
					summary.event_type
				}
				message_id:      if req.message_id.trim_space() != '' {
					req.message_id
				} else {
					summary.message_id
				}
				target:          if req.target.trim_space() != '' {
					req.target
				} else {
					summary.target
				}
				target_type:     if req.target_type.trim_space() != '' {
					req.target_type
				} else {
					summary.target_type
				}
				open_message_id: summary.open_message_id
				action_tag:      summary.action_tag
			}, req.payload) or {
				return ctx.js_string(json.encode(FeishuCardBridgeResult{
					error: err.msg()
				}))
			}
			return ctx.js_string(json.encode(result))
		})
	}
}

fn InProcVjsxHostApi.websocket_dispatch_builder(mut state VjsxExecutorState, idx int) vjsx.HostValueBuilder {
	return fn [mut state, idx] (ctx &vjsx.Context) vjsx.Value {
		return ctx.js_function(fn [ctx, mut state, idx] (args []vjsx.Value) vjsx.Value {
			if args.len == 0 {
				return ctx.js_string('')
			}
			raw := args[0].to_string().trim_space()
			if raw == '' {
				return ctx.js_string('')
			}
			req := json.decode(InProcVjsxHostWebSocketDispatchRequest, raw) or {
				return ctx.js_string(json.encode(InProcVjsxHostWebSocketDispatchResponse{
					error: 'invalid_websocket_dispatch_request'
				}))
			}
			mut app_ref := AppFacade(unsafe { nil })
			state.mu.@lock()
			if idx >= 0 && idx < state.hosts.len {
				if state.hosts[idx].request_ctx.active {
					app_ref = state.hosts[idx].request_ctx.app
				} else {
					app_ref = state.hosts[idx].app_ref
				}
			}
			state.mu.unlock()
			if isnil(app_ref) {
				return ctx.js_string(json.encode(InProcVjsxHostWebSocketDispatchResponse{
					error: 'websocket_dispatch_app_missing'
				}))
			}
			mut app := app_ref
			result := app.execute_websocket_dispatch_commands_result(req.commands)
			if result.has_close {
				return ctx.js_string(json.encode(InProcVjsxHostWebSocketDispatchResponse{
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
				}))
			}
			return ctx.js_string(json.encode(InProcVjsxHostWebSocketDispatchResponse{
				ok:       true
				failures: result.failures
			}))
		})
	}
}
