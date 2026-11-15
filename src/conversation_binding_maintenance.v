module main

import connection_runtime
import time

fn (mut app App) start_reply_maintenance() {
	if mut run := app.lifecycle.reply_runs.reserve('reply-maintenance') {
		spawn app.run_reply_maintenance(mut run)
	}
}

fn (mut app App) run_reply_maintenance(mut run connection_runtime.Run) {
	defer { app.lifecycle.reply_runs.release('reply-maintenance', mut run) }
	for run.wait(time.second) { app.prune_reply_resources(time.now().unix_milli()) }
}

fn (mut app App) touch_reply_stream(stream string) {
	if stream == '' { return }
	app.providers.codex.mu.@lock()
	app.providers.codex.runtime.reply_sessions.touch(stream)
	for _, mut rt in app.providers.codex.instances { rt.reply_sessions.touch(stream) }
	app.providers.codex.mu.unlock()
}

fn (mut app App) prune_reply_resources(now i64) {
	app.providers.feishu.mu.@lock()
	for release in app.providers.feishu.prune_expired_buffers_unlocked(now) {
		app.release_reply_binding(release.binding_release())
	}
	app.providers.feishu.mu.unlock()
	app.providers.codex.mu.@lock()
	for stream in app.providers.codex.runtime.reply_sessions.prune_expired(now) {
		app.providers.codex.runtime.clear_stream_targets(stream)
		app.providers.codex.error_bursts.cancel_stream('main', stream)
	}
	app.providers.codex.runtime.prune_pending_rpcs(now)
	for instance in app.providers.codex.instances.keys() {
		mut rt := app.providers.codex.instances[instance] or { continue }
		rt.prune_pending_rpcs(now)
		for stream in rt.reply_sessions.prune_expired(now) {
			rt.clear_stream_targets(stream)
			app.providers.codex.error_bursts.cancel_stream(instance, stream)
		}
		app.providers.codex.instances[instance] = rt
	}
	app.providers.codex.mu.unlock()
}
