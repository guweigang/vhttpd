module main

import log
import time
import upstream
import codex
import feishu

const feishu_stream_buffer_rollover_runes = feishu.stream_buffer_rollover_runes

// ── Stream Buffering ───────────────────────────────────────────────────

fn (mut app App) feishu_runtime_buffer_patch(req upstream.UpstreamSendRequest) {
	mut current_target := req.target
	if current_target == '' {
		return
	}

	for {
		app.providers.feishu.mu.@lock()
		if current_target !in app.providers.feishu.buffers {
			app.providers.feishu.buffers[current_target] = feishu.StreamBuffer{
				message_id:    current_target
				app:           req.instance
				last_flush:    time.now().unix_milli()
				segment_index: 1
			}
		}
		mut buf := app.providers.feishu.buffers[current_target]
		if !buf.sealed {
			buf.content += req.text
			buf.last_delta = time.now().unix_milli()
			app.providers.feishu.buffers[current_target] = buf
			app.providers.feishu.mu.unlock()
			return
		}
		if buf.next_message_id != '' {
			next_target := buf.next_message_id
			app.providers.feishu.mu.unlock()
			current_target = next_target
			continue
		}
		app_name := buf.app
		stream_id := buf.stream_id
		receive_id := buf.receive_id
		receive_id_type := buf.receive_id_type
		segment_index := if buf.segment_index > 0 { buf.segment_index + 1 } else { 2 }
		app.providers.feishu.mu.unlock()

		if receive_id.trim_space() == '' || receive_id_type.trim_space() == '' {
			return
		}

		card_payload := feishu.SendMessageRequest.streaming_card(req.text, segment_index)
		send_result := app.feishu_runtime_send_message(feishu.SendMessageRequest{
			app:             app_name
			receive_id_type: receive_id_type
			receive_id:      receive_id
			msg_type:        'interactive'
			content:         card_payload
		}) or {
			log.error('[feishu] ❌ open next preview failed for ${current_target}: ${err}')
			return
		}

		now := time.now().unix_milli()
		app.providers.feishu.mu.@lock()
		if mut sealed_buf := app.providers.feishu.buffers[current_target] {
			if sealed_buf.next_message_id == '' {
				sealed_buf.next_message_id = send_result.message_id
				app.providers.feishu.buffers[current_target] = sealed_buf
			}
		}
		app.providers.feishu.buffers[send_result.message_id] = feishu.StreamBuffer{
			message_id:       send_result.message_id
			app:              app_name
			content:          req.text
			rendered_content: req.text
			last_delta:       now
			last_flush:       now
			stream_id:        stream_id
			receive_id:       receive_id
			receive_id_type:  receive_id_type
			segment_index:    segment_index
		}
		app.providers.feishu.mu.unlock()
		if stream_id != '' {
			app.codex_add_stream_target(app.codex_resolve_instance_for_stream(stream_id),
				stream_id, codex.CodexTarget{
				platform:   'feishu'
				message_id: send_result.message_id
			})
			app.dispatch_feishu_message_sent(stream_id, send_result.message_id)
		}
		return
	}
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
	send_result := app.feishu_runtime_send_message(feishu.SendMessageRequest{
		app:             buf.app
		receive_id_type: buf.receive_id_type
		receive_id:      buf.receive_id
		msg_type:        'interactive'
		content:         card_payload
	})!
	if buf.stream_id.trim_space() != '' {
		app.codex_add_stream_target(app.codex_resolve_instance_for_stream(buf.stream_id),
			buf.stream_id, codex.CodexTarget{
			platform:   'feishu'
			message_id: send_result.message_id
		})
		app.dispatch_feishu_message_sent(buf.stream_id, send_result.message_id)
	}
	return send_result.message_id
}

fn (mut app App) feishu_runtime_run_buffer_flusher() {
	log.info('[feishu] 🔄 stream buffer flusher started')
	for {
		time.sleep(400 * time.millisecond)
		app.feishu_runtime_flush_pending_buffers()
	}
}

fn (mut app App) feishu_runtime_flush_pending_buffers() {
	if app.feishu_runtime_bridge_proxy_only() {
		return
	}
	now := time.now().unix_milli()
	mut to_flush := []feishu.StreamBuffer{}

	app.providers.feishu.mu.@lock()
	for _, buf in app.providers.feishu.buffers {
		if buf.last_delta >= buf.last_flush && now - buf.last_flush >= 400
			&& buf.content.trim_space() != '' {
			to_flush << buf
		}
	}
	app.providers.feishu.mu.unlock()

	for buf in to_flush {
		preview_markdown := feishu.StreamBuffer.streaming_preview_markdown(buf.content)
		if preview_markdown == '' {
			continue
		}
		if preview_markdown == buf.rendered_content {
			app.providers.feishu.mu.@lock()
			if mut active := app.providers.feishu.buffers[buf.message_id] {
				active.last_flush = time.now().unix_milli()
				app.providers.feishu.buffers[buf.message_id] = active
			}
			app.providers.feishu.mu.unlock()
			continue
		}
		card_payload := feishu.SendMessageRequest.streaming_card(preview_markdown, 1)
		app.feishu_runtime_update_message(feishu.UpdateMessageRequest{
			app:        buf.app
			message_id: buf.message_id
			msg_type:   'interactive'
			content:    card_payload
		}) or {
			log.error('[feishu] ❌ preview flush failed for ${buf.message_id}: ${err}')
			continue
		}
		app.providers.feishu.mu.@lock()
		if mut active := app.providers.feishu.buffers[buf.message_id] {
			active.last_flush = time.now().unix_milli()
			active.rendered_content = preview_markdown
			app.providers.feishu.buffers[buf.message_id] = active
		}
		app.providers.feishu.mu.unlock()
	}
}

fn (mut app App) feishu_runtime_flush_buffer(message_id string, template_content string, finish bool) ! {
	if app.feishu_runtime_bridge_proxy_only() {
		if finish {
			log.info('[feishu] 🚿 explicit flush skipped in bridge proxy mode for msg_id=${message_id} (finish=true)')
			return
		}
		return error('feishu_bridge_proxy_only')
	}
	app.providers.feishu.mu.@lock()
	buf := app.providers.feishu.buffers[message_id] or {
		app.providers.feishu.mu.unlock()
		if finish {
			log.info('[feishu] 🚿 explicit flush without buffer for msg_id=${message_id} (finish=true, fallback=no-op)')
			return
		}
		return error('no buffer found for message_id: ${message_id}')
	}
	app.providers.feishu.mu.unlock()

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
		head, mut tail := feishu.StreamBuffer.split_content_runes(content,
			feishu_stream_buffer_rollover_runes)
		final_head := if tail == '' {
			feishu.StreamBuffer.render_final_card(head, content_raw)
		} else {
			feishu.SendMessageRequest.interactive_markdown_card(head)
		}
		app.feishu_runtime_update_message(feishu.UpdateMessageRequest{
			app:        buf.app
			message_id: buf.message_id
			msg_type:   'interactive'
			content:    final_head
		})!
		mut segment := 2
		mut last_message_id := buf.message_id
		for tail != '' {
			head_chunk, next_tail := feishu.StreamBuffer.split_content_runes(tail,
				feishu_stream_buffer_rollover_runes)
			is_last := next_tail == ''
			mut followup_buf := buf
			followup_buf.segment_index = segment
			last_message_id = app.feishu_runtime_send_followup_segment(followup_buf, head_chunk,
				is_last, content_raw)!
			tail = next_tail
			segment++
		}
		app.providers.feishu.mu.@lock()
		if mut active := app.providers.feishu.buffers[buf.message_id] {
			active.content = ''
			active.rendered_content = content
			active.last_flush = time.now().unix_milli()
			active.last_delta = active.last_flush
			active.sealed = true
			active.next_message_id = ''
			active.segment_index = if last_message_id == buf.message_id { 1 } else { segment }
			app.providers.feishu.buffers[buf.message_id] = active
		}
		if last_message_id != buf.message_id {
			app.providers.feishu.buffers.delete(last_message_id)
		}
		app.providers.feishu.mu.unlock()
		return
	}

	if buf.content.trim_space() == '' {
		return
	}
	preview_markdown := feishu.StreamBuffer.streaming_preview_markdown(buf.content)
	if preview_markdown == '' {
		return
	}
	app.feishu_runtime_update_message(feishu.UpdateMessageRequest{
		app:        buf.app
		message_id: buf.message_id
		msg_type:   'interactive'
		content:    feishu.SendMessageRequest.streaming_card(preview_markdown, 1)
	})!
	app.providers.feishu.mu.@lock()
	if mut active := app.providers.feishu.buffers[buf.message_id] {
		active.last_flush = time.now().unix_milli()
		active.rendered_content = preview_markdown
		app.providers.feishu.buffers[buf.message_id] = active
	}
	app.providers.feishu.mu.unlock()
}
