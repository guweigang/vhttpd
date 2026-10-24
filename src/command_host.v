module main

import codex
import command
import upstream
import feishu

interface UpstreamMessageHost {
mut:
	websocket_upstream_send(req upstream.UpstreamSendRequest) !upstream.UpstreamSendResult
	websocket_upstream_update(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult
}

pub interface CodexCommandHost {
mut:
	codex_bind_stream_to_thread(instance string, thread_id string, stream_id string) string
	codex_add_stream_target(instance string, stream_id string, target codex.CodexTarget)
	codex_clear_thread_binding(instance string, thread_id string) bool
	codex_clear_stream_targets(instance string, stream_id string) bool
	codex_start_turn_normalized(cmd command.NormalizedCommand) !
	codex_reply_rpc(instance string, id string, result string) !
	codex_send_rpc(instance string, method string, params string, stream_id string, message_id string) !int
}

pub interface FeishuCommandHost {
	UpstreamMessageHost
mut:
	codex_find_stream_targets(stream_id string) []codex.CodexTarget
	codex_add_stream_target(instance string, stream_id string, target codex.CodexTarget)
	codex_rebind_stream_target(instance string, stream_id string, target codex.CodexTarget)
	codex_release_feishu_targets(released feishu.WireStreamRelease)
	codex_resolve_instance_for_stream(stream_id string) string
	codex_clear_stream_targets_any(stream_id string) bool
	feishu_runtime_execute_stream_command(admission feishu.StreamCommand, req upstream.UpstreamSendRequest, action string, finish bool) !upstream.UpstreamUpdateResult
	dispatch_feishu_message_sent(receipt feishu.SentReceipt)
	dispatch_feishu_message_updated(stream_id string, message_id string)
	command_feishu_state() &feishu.FeishuState
	command_feishu_bridge_enabled() bool
	command_feishu_bridge_proxy_append(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult
	command_feishu_bridge_proxy_finish(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult
	command_feishu_bridge_proxy_fail(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult
}

pub interface GenericCommandHost {
	UpstreamMessageHost
mut:
	restart_all_workers() int
}

interface FeishuBridgeRevocationHost {
mut:
	command_feishu_bridge_proxy_clear(req upstream.UpstreamSendRequest, released feishu.WireStreamRelease) !
}

interface FeishuBridgeBindingHost {
	FeishuCommandHost
mut:
	command_feishu_bridge_bind(claim feishu.BridgeBind) !string
	command_feishu_bridge_cancel_bind(claim feishu.BridgeBind, generation string) !
}

interface FeishuBridgeStreamCompletionHost {
mut:
	command_feishu_bridge_stream_operation(req upstream.UpstreamSendRequest, op feishu.BridgeStreamOperation, action string) !upstream.UpstreamUpdateResult
	command_feishu_bridge_cancel_stream_operation(op feishu.BridgeStreamOperation) !
}

interface FeishuMessageUpdateBridgeHost {
mut:
	command_feishu_bridge_message_update(claim feishu.MessageUpdate, req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult
}
