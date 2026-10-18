module main

import connection_runtime
import log
import time
import upstream
import codex
import feishu

const feishu_stream_buffer_rollover_runes = feishu.stream_buffer_rollover_runes

// ── Stream Buffering ───────────────────────────────────────────────────

fn (mut app App) feishu_runtime_buffer_patch(req upstream.UpstreamSendRequest) {
	claim := app.providers.feishu.append_buffer_patch(req.target, req.instance, req.text) or { return }
	app.feishu_runtime_send_rollover(claim)
}

fn (mut app App) feishu_runtime_send_rollover(claim feishu.BufferRollover) {
	mut committed := false
	defer { if !committed { app.providers.feishu.cancel_buffer_rollover(claim) } }
	buf := claim.buffer
	card_payload := feishu.SendMessageRequest.streaming_card(claim.content, claim.segment_index)
	result := app.providers.feishu_provider_runtime_send_message(feishu.SendMessageRequest{
		app:             buf.app
		receive_id_type: buf.receive_id_type
		receive_id:      buf.receive_id
		msg_type:        'interactive'
		content:         card_payload
	}, mut app) or {
		log.error('[feishu] ❌ open next preview failed for ${buf.message_id}: ${err}')
		return
	}
	committed = app.feishu_runtime_commit_rollover(claim, result.message_id)
	if committed && buf.stream_id != '' {
		app.dispatch_feishu_message_sent(buf.stream_id, result.message_id)
	}
}

fn (mut app App) feishu_runtime_commit_rollover(claim feishu.BufferRollover, message_id string) bool {
	app.providers.feishu.mu.@lock()
	defer { app.providers.feishu.mu.unlock() }
	if !app.providers.feishu.commit_buffer_rollover_unlocked(claim, message_id, time.now().unix_milli()) {
		return false
	}
	// State-only publication while the buffer owner is locked. Dispatch callbacks
	// and all HTTP I/O run after unlock. Lock order is FeishuState then CodexState.
	stream_id := claim.buffer.stream_id
	if stream_id != '' {
		app.codex_add_stream_target(app.codex_resolve_instance_for_stream(stream_id), stream_id,
			codex.CodexTarget{ platform: 'feishu', message_id: message_id })
	}
	return true
}

fn (mut app App) feishu_runtime_send_followup_segment(buf feishu.StreamBuffer, markdown string, finish bool, template_content string) !string {
	if buf.receive_id.trim_space() == '' || buf.receive_id_type.trim_space() == '' {
		return error('stream followup segment missing send context')
	}
	card_payload := if finish {
		feishu.StreamBuffer.render_final_card(markdown, template_content)
	} else {
		feishu.SendMessageRequest.streaming_card(markdown, buf.segment_index)
	}
	send_result := app.providers.feishu_provider_runtime_send_message(feishu.SendMessageRequest{
		app:             buf.app
		receive_id_type: buf.receive_id_type
		receive_id:      buf.receive_id
		msg_type:        'interactive'
		content:         card_payload
	}, mut app)!

	return send_result.message_id
}

// Transport-only followup sending above grants no target publication authority.
fn (mut app App) feishu_runtime_send_finish_segment(claim feishu.BufferFinish, markdown string, finish bool, template_content string, segment_index int) !string {
	if !app.providers.feishu.buffer_finish_is_current(claim) {
		return error('feishu buffer finish retired')
	}
	mut buf := claim.buffer
	buf.segment_index = segment_index
	message_id := app.feishu_runtime_send_followup_segment(buf, markdown, finish, template_content)!
	if !app.feishu_runtime_publish_finish_segment(claim, message_id) {
		return error('feishu buffer finish retired')
	}
	if buf.stream_id.trim_space() != '' {
		app.dispatch_feishu_message_sent(buf.stream_id, message_id)
	}
	return message_id
}

fn (mut app App) feishu_runtime_publish_finish_segment(claim feishu.BufferFinish, message_id string) bool {
	app.providers.feishu.mu.@lock()
	defer { app.providers.feishu.mu.unlock() }
	if message_id == '' || !app.providers.feishu.buffer_finish_is_current_unlocked(claim) {
		return false
	}
	stream_id := claim.buffer.stream_id
	if stream_id.trim_space() != '' {
		app.codex_add_stream_target(app.codex_resolve_instance_for_stream(stream_id), stream_id,
			codex.CodexTarget{ platform: 'feishu', message_id: message_id })
	}
	return true
}

fn (mut app App) feishu_runtime_run_buffer_flusher(mut run connection_runtime.Run) {
	defer { app.providers.feishu.background_runs.release('buffer-flusher', mut run) }
	log.info('[feishu] 🔄 stream buffer flusher started')
	for run.wait(400 * time.millisecond) {
		app.feishu_runtime_flush_pending_buffers()
	}
}

fn (mut app App) feishu_runtime_flush_pending_buffers() {
	if app.providers.feishu_runtime_bridge_proxy_only() {
		return
	}
	to_flush := app.providers.feishu.pending_buffer_snapshots(time.now().unix_milli())

	for buf in to_flush {
		if !app.providers.feishu.buffer_snapshot_is_current(buf) { continue }
		preview_markdown := feishu.StreamBuffer.streaming_preview_markdown(buf.content)
		if preview_markdown == '' {
			continue
		}
		if preview_markdown == buf.rendered_content {
			app.providers.feishu.commit_buffer_preview(buf, preview_markdown, time.now().unix_milli())
			continue
		}
		card_payload := feishu.SendMessageRequest.streaming_card(preview_markdown, 1)
		app.providers.feishu_provider_runtime_update_message(feishu.UpdateMessageRequest{
			app:        buf.app
			message_id: buf.message_id
			msg_type:   'interactive'
			content:    card_payload
		}, mut app) or {
			log.error('[feishu] ❌ preview flush failed for ${buf.message_id}: ${err}')
			continue
		}
		app.providers.feishu.commit_buffer_preview(buf, preview_markdown, time.now().unix_milli())
	}
}

fn (mut app App) feishu_runtime_flush_buffer(message_id string, template_content string, finish bool) ! {
	if app.providers.feishu_runtime_bridge_proxy_only() {
		if finish {
			log.info('[feishu] 🚿 explicit flush skipped in bridge proxy mode for msg_id=${message_id} (finish=true)')
			return
		}
		return error('feishu_bridge_proxy_only')
	}
	buf := app.providers.feishu.buffer_snapshot(message_id) or {
		if finish { return }
		return error('no buffer found for message_id: ${message_id}')
	}
	if buf.sealed { return }

	log.info('[feishu] 🚿 explicit flush for msg_id=${message_id} (finish=${finish})')

	content_raw := if template_content != '' {
		template_content
	} else {
		'{"elements":[{"tag":"markdown","content":"{{content}}"}]}'
	}

	if finish {
		mut content := buf.content
		if content.trim_space() == '' {
			content = buf.rendered_content
		}
		content = content.trim_space()
		if content == '' {
			log.info('[feishu] 🚿 finish flush skipped for msg_id=${message_id} (empty buffer)')
			return
		}
		claim := app.providers.feishu.begin_buffer_finish(buf) or { return error('feishu buffer finish changed or in progress') }
		defer { app.providers.feishu.cancel_buffer_finish(claim) }
		head, mut tail := feishu.StreamBuffer.split_content_runes(content,
			feishu_stream_buffer_rollover_runes)
		final_head := if tail == '' {
			feishu.StreamBuffer.render_final_card(head, content_raw)
		} else {
			feishu.SendMessageRequest.interactive_markdown_card(head)
		}
		app.providers.feishu_provider_runtime_update_message(feishu.UpdateMessageRequest{
			app:        buf.app
			message_id: buf.message_id
			msg_type:   'interactive'
			content:    final_head
		}, mut app)!
		mut segment := 2
		mut last_message_id := buf.message_id
		for tail != '' {
			head_chunk, next_tail := feishu.StreamBuffer.split_content_runes(tail,
				feishu_stream_buffer_rollover_runes)
			is_last := next_tail == ''
			last_message_id = app.feishu_runtime_send_finish_segment(claim, head_chunk,
				is_last, content_raw, segment)!
			tail = next_tail
			segment++
		}
		segment_index := if last_message_id == buf.message_id { 1 } else { segment }
		if !app.providers.feishu.commit_buffer_finish_claim(claim, content, segment_index, time.now().unix_milli()) {
			return error('feishu buffer changed during finish')
		}
		return
	}

	if !app.providers.feishu.buffer_snapshot_is_current(buf) {
		return error('feishu buffer changed or finishing')
	}
	if buf.content.trim_space() == '' {
		return
	}
	preview_markdown := feishu.StreamBuffer.streaming_preview_markdown(buf.content)
	if preview_markdown == '' {
		return
	}
	app.providers.feishu_provider_runtime_update_message(feishu.UpdateMessageRequest{
		app:        buf.app
		message_id: buf.message_id
		msg_type:   'interactive'
		content:    feishu.SendMessageRequest.streaming_card(preview_markdown, 1)
	}, mut app)!
	app.providers.feishu.commit_buffer_preview(buf, preview_markdown, time.now().unix_milli())
}
