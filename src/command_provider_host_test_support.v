module main

import executor
import feishu
import upstream

// Implements only the generic command and bridge capabilities used below.
@[heap]
struct NarrowCommandBridgeHost {
mut:
	state      feishu.FeishuState
	sent       int
	dispatched int
	message_id string = 'first'
}

fn (mut h NarrowCommandBridgeHost) websocket_upstream_send(_req upstream.UpstreamSendRequest) !upstream.UpstreamSendResult {
	h.sent++
	return upstream.UpstreamSendResult{ ok: true, message_id: h.message_id }
}

fn (mut h NarrowCommandBridgeHost) websocket_upstream_update(_req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	return upstream.UpstreamUpdateResult{ ok: true, message_id: h.message_id }
}

fn (mut _ NarrowCommandBridgeHost) restart_all_workers() int { return 3 }

fn (mut h NarrowCommandBridgeHost) bridge_context() FeishuCardBridgeContext {
	return FeishuCardBridgeContext{ state: &h.state }
}

fn (mut h NarrowCommandBridgeHost) bridge_dispatch_request(_req feishu.BridgeDispatchRequest, _kind string) !executor.KernelWebSocketUpstreamDispatchOutcome {
	h.dispatched++
	return executor.KernelWebSocketUpstreamDispatchOutcome{}
}

fn (mut h NarrowCommandBridgeHost) command_feishu_state() &feishu.FeishuState { return &h.state }

fn (mut _ NarrowCommandBridgeHost) feishu_runtime_buffer_patch(_req upstream.UpstreamSendRequest) {}

fn (mut _ NarrowCommandBridgeHost) feishu_runtime_flush_buffer(_id string, _content string, _finish bool) ! {}

fn (mut _ NarrowCommandBridgeHost) feishu_runtime_execute_stream_command(_admission feishu.StreamCommand, _req upstream.UpstreamSendRequest, _action string, _finish bool) !upstream.UpstreamUpdateResult {
	return error('unused_stream_command')
}

