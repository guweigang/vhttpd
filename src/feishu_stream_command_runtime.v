module main

import feishu
import upstream

// Every state mutation keeps the caller's original local admission. Transport
// calls run after the state transition has released its mutex.
fn (mut app App) feishu_runtime_execute_stream_command(admission feishu.StreamCommand, req upstream.UpstreamSendRequest, action string, finish bool) !upstream.UpstreamUpdateResult {
	mut state := &app.providers.feishu
	buf := state.stream_command_snapshot(admission) or { return error('feishu_stream_command_retired') }
	if req.target != buf.message_id { return error('feishu_stream_command_retired') }
	match action {
		'append' {
			result := state.append_stream_command(admission, req.text)!
			if claim := result.rollover { app.feishu_runtime_send_rollover(claim) }
		}
		'finish' {
			app.feishu_runtime_flush_captured_buffer(buf, req.content, finish)!
		}
		'fail' {
			claim := state.begin_stream_failure(admission) or { return error('feishu_stream_command_retired') }
			defer { app.feishu_runtime_finish_stream_failure(claim) }
			update := upstream.UpstreamSendRequest{ ...req, provider: 'feishu', instance: buf.app }
			result := app.websocket_upstream_update(update)!
			if !app.feishu_runtime_finish_stream_failure(claim) { return error('feishu_stream_command_retired') }
			return result
		}
		else { return error('unsupported_feishu_stream_action:${action}') }
	}
	return upstream.UpstreamUpdateResult{ ok: true, provider: 'feishu', instance: buf.app, message_id: buf.message_id }
}

fn (mut app App) feishu_runtime_finish_stream_failure(claim feishu.StreamFailure) bool {
	mut state := &app.providers.feishu
	state.mu.@lock()
	defer { state.mu.unlock() }
	released := state.finish_stream_failure_release_unlocked(claim) or { return false }
	app.codex_release_feishu_targets(released)
	return true
}
