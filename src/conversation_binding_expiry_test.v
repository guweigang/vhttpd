module main

import conversation_binding
import feishu

fn test_buffer_expiry_releases_matching_binding_and_preserves_other_channel() {
	mut app := &App{}
	app.providers.feishu.register_stream_buffer('message', 'stream', 'main', '', '', 'content')
	buf := app.providers.feishu.buffer_snapshot('message') or { panic('missing') }
	app.publish_reply_binding('stream', conversation_binding.ReplyTarget{
		platform: 'feishu'
		message_id: 'message'
		stream_generation: buf.generation
	})
	app.publish_reply_binding('stream', conversation_binding.ReplyTarget{platform: 'custom', message_id: 'other'})
	app.providers.codex.runtime.reply_sessions.touch('stream')
	app.providers.feishu.mu.@lock()
	for release in app.providers.feishu.prune_expired_buffers_unlocked(buf.last_delta + feishu.buffer_ttl_ms + 1) {
		app.release_reply_binding(release.binding_release())
	}
	app.providers.feishu.mu.unlock()
	assert app.providers.feishu.buffers.len == 0
	targets := app.find_reply_bindings('stream')
	assert targets.len == 1
	assert targets[0].platform == 'custom'
}

fn test_reply_maintenance_stops_and_joins_without_feishu_enabled() {
	mut app := &App{}
	app.start_reply_maintenance()
	app.start_reply_maintenance()
	mut runs := app.lifecycle.reply_runs.request_shutdown()
	assert runs.len == 1
	for mut run in runs { run.wait_finished() }
	app.start_reply_maintenance()
	assert app.lifecycle.reply_runs.request_shutdown().len == 0
}
