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
	codex_resolve_instance_for_stream(stream_id string) string
	codex_clear_stream_targets_any(stream_id string) bool
	feishu_runtime_buffer_patch(req upstream.UpstreamSendRequest)
	feishu_runtime_flush_buffer(message_id string, template_content string, finish bool) !
	dispatch_feishu_message_sent(stream_id string, message_id string)
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
