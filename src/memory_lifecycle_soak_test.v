module main

import os
import time
import codex
import feishu
import ws
import conversation_binding

fn memory_lifecycle_soak_batch(mut app App, mut hub ws.HubState, round int) {
	for index in 0 .. 128 {
		id := '${round}-${index}'
		app.providers.feishu.register_stream_buffer(id, id, 'main', '', '', 'x'.repeat(8192))
		buf := app.providers.feishu.buffer_snapshot(id) or { panic('missing buffer') }
		app.publish_reply_binding(id, conversation_binding.ReplyTarget{
			platform:          'feishu'
			message_id:        id
			stream_generation: buf.generation
		})
		app.codex_remember_pending_rpc('main', index, codex.PendingRpc{ stream_id: id })
		if index % 2 == 0 {
			_, found := app.codex_take_pending_rpc('main', index)
			assert found
		}
		assert ws.hub_send_to(mut hub, id, 'x'.repeat(4096), 'text')
		ws.hub_close_target(mut hub, id, 1000, '')
	}
	app.prune_reply_resources(time.now().unix_milli() + feishu.buffer_ttl_ms + 1)
	assert app.providers.feishu.buffers.len == 0
	assert app.providers.codex.runtime.reply_sessions.streams().len == 0
	assert app.providers.codex.runtime.pending_rpcs.len == 0
	assert hub.pending.len == 0
}

fn test_memory_lifecycle_long_soak() {
	seconds := os.getenv('VHTTPD_MEMORY_SOAK_SECONDS').int()
	if seconds <= 0 { return }
	assert seconds >= 180
	assert gc_is_enabled()
	mut app := &App{}
	mut hub := ws.HubState{}
	clock := time.new_stopwatch()
	mut round := 0
	mut next_sample := i64(0)
	mut baseline := u64(0)
	for clock.elapsed().seconds() < seconds {
		elapsed := i64(clock.elapsed().seconds())
		if elapsed < seconds - 60 {
			memory_lifecycle_soak_batch(mut app, mut hub, round)
			round++
		} else {
			gc_collect()
			time.sleep(time.second)
		}
		if elapsed >= 30 && baseline == 0 {
			gc_collect()
			baseline = u64(gc_memory_use())
		}
		if elapsed >= next_sample {
			println('MEMORY_SOAK elapsed=${elapsed} rounds=${round} heap=${gc_memory_use()}')
			next_sample = elapsed + 10
		}
	}
	gc_collect()
	settled := u64(gc_memory_use())
	println('MEMORY_SOAK_RESULT baseline=${baseline} settled=${settled} rounds=${round}')
	assert settled <= baseline + 32 * 1024 * 1024
}

fn test_completed_reply_lifecycles_release_captured_state() {
	mut app := &App{}
	mut hub := ws.HubState{}
	for round in 0 .. 4 { memory_lifecycle_soak_batch(mut app, mut hub, round) }
	gc_collect()
	baseline := gc_memory_use()
	for round in 4 .. 132 { memory_lifecycle_soak_batch(mut app, mut hub, round) }
	gc_collect()
	settled := gc_memory_use()
	assert !gc_is_enabled() || settled <= baseline + 8 * 1024 * 1024
}

fn test_completed_codex_rpc_callbacks_release_metadata() {
	mut app := &App{}
	for index in 0 .. 32 {
		app.codex_remember_pending_rpc('main', index, codex.PendingRpc{ stream_id: 'warmup' })
		_, found := app.codex_take_pending_rpc('main', index)
		assert found
	}
	gc_collect()
	baseline := gc_memory_use()
	for index in 0 .. 8192 {
		app.codex_remember_pending_rpc('main', index, codex.PendingRpc{
			stream_id: '${index}-' + 'x'.repeat(2048)
		})
		_, found := app.codex_take_pending_rpc('main', index)
		assert found
	}
	gc_collect()
	assert app.providers.codex.runtime.pending_rpcs.len == 0
	settled := gc_memory_use()
	assert !gc_is_enabled() || settled <= baseline + 8 * 1024 * 1024, 'completed Codex RPC callbacks retained metadata: ${baseline} -> ${settled}'
}
