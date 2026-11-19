module main

import conversation_binding
import codex

fn (mut app App) find_reply_bindings(stream string) []conversation_binding.ReplyTarget {
	mut targets := []conversation_binding.ReplyTarget{}
	for target in app.codex_find_stream_targets(stream) { targets << conversation_binding.ReplyTarget(target) }
	return targets
}

fn (mut app App) rebind_reply_binding(stream string, target conversation_binding.ReplyTarget) {
	app.codex_rebind_stream_target(app.codex_resolve_instance_for_stream(stream), stream, codex.CodexTarget(target))
}

fn (mut app App) publish_reply_binding(stream string, target conversation_binding.ReplyTarget) {
	if stream == '' || target.platform == '' || target.message_id == '' { return }
	app.codex_add_stream_target(app.codex_resolve_instance_for_stream(stream), stream,
		codex.CodexTarget(target))
}

fn (mut app App) release_reply_binding(release conversation_binding.Release) {
	codex_release_reply_targets_in_state(mut app.providers.codex, release)
}

fn (mut providers ProviderRuntimeHub) feishu_card_bridge_context() FeishuCardBridgeContext {
	mut engine := &providers.codex
	return FeishuCardBridgeContext{
		state: &providers.feishu
		release_binding: fn [mut engine] (release conversation_binding.Release) {
			codex_release_reply_targets_in_state(mut engine, release)
		}
	}
}
