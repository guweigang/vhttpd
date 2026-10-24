module main

import feishu
import executor
import time
import upstream

interface FeishuBridgeClientHost {
mut:
	bridge_context() FeishuCardBridgeContext
	bridge_dispatch_request(req feishu.BridgeDispatchRequest, event_kind string) !executor.KernelWebSocketUpstreamDispatchOutcome
}

interface FeishuBridgeProxyHost {
	UpstreamMessageHost
mut:
	bridge_context() FeishuCardBridgeContext
	command_feishu_state() &feishu.FeishuState
	feishu_runtime_execute_stream_command(admission feishu.StreamCommand, req upstream.UpstreamSendRequest, action string, finish bool) !upstream.UpstreamUpdateResult
}

fn (mut app App) bridge_context() FeishuCardBridgeContext {
	return app.providers.feishu_card_bridge_context()
}

fn (mut app App) bridge_dispatch_request(req feishu.BridgeDispatchRequest, event_kind string) !executor.KernelWebSocketUpstreamDispatchOutcome {
	return app.kernel_dispatch_websocket_upstream_handled(app.kernel_websocket_upstream_dispatch_request_with_event(event_kind,
		req.request_id, websocket_upstream_provider_feishu, if req.app.trim_space() != '' {
			req.app
		} else {
			'main'
		},
		if req.trace_id.trim_space() != '' { req.trace_id } else { req.request_id }, req.event_type,
		req.message_id, req.target, req.target_type, req.payload, time.now().unix(), req.metadata.clone()))
}
