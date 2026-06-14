module feishu

import command
import json
import net.http
import upstream

// ── Message Content Building ──

pub fn SendMessageRequest.build_content(msg_type string, raw_content string, text string, content_fields map[string]string) !string {
	content := raw_content.trim_space()
	if content != '' {
		return content
	}
	match msg_type {
		'text' {
			text_value := if text.trim_space() != '' {
				text
			} else {
				content_fields['text'] or { '' }
			}
			if text_value.trim_space() == '' {
				return error('missing text content')
			}
			return json.encode({
				'text': text_value
			})
		}
		'image' {
			image_key := content_fields['image_key'] or { '' }
			if image_key.trim_space() == '' {
				return error('missing image_key')
			}
			return json.encode({
				'image_key': image_key
			})
		}
		'file', 'audio', 'sticker' {
			file_key := content_fields['file_key'] or { '' }
			if file_key.trim_space() == '' {
				return error('missing file_key')
			}
			return json.encode({
				'file_key': file_key
			})
		}
		'media' {
			file_key := content_fields['file_key'] or { '' }
			image_key := content_fields['image_key'] or { '' }
			file_name := content_fields['file_name'] or { '' }
			duration := content_fields['duration'] or { '' }
			if file_key.trim_space() == '' {
				return error('missing file_key')
			}
			if image_key.trim_space() == '' {
				return error('missing image_key')
			}
			if file_name.trim_space() == '' {
				return error('missing file_name')
			}
			if duration.trim_space() == '' {
				return error('missing duration')
			}
			return json.encode({
				'file_key':  file_key
				'image_key': image_key
				'file_name': file_name
				'duration':  duration
			})
		}
		'post', 'interactive', 'share_chat', 'share_user' {
			return error('missing raw content for msg_type ${msg_type}')
		}
		else {
			return error('unsupported feishu msg_type ${msg_type}')
		}
	}
}

pub fn SendMessageRequest.extract_markdown_text(raw_content string, text string, content_fields map[string]string) string {
	if text.trim_space() != '' {
		return text
	}
	text_field := content_fields['text'] or { '' }
	if text_field.trim_space() != '' {
		return text_field
	}
	content := raw_content.trim_space()
	if content == '' {
		return ''
	}
	decoded := json.decode(TextContent, content) or { return content }
	if decoded.text.trim_space() != '' {
		return decoded.text
	}
	return content
}

pub fn SendMessageRequest.interactive_markdown_card(markdown string) string {
	return '{"elements":[{"tag":"markdown","content":${json.encode(markdown)}}]}'
}

pub fn SendMessageRequest.streaming_card(markdown string, segment_index int) string {
	if segment_index <= 1 {
		return SendMessageRequest.interactive_markdown_card(markdown)
	}
	return '{"elements":[{"tag":"note","elements":[{"tag":"plain_text","content":${json.encode('继续输出 · 第 ${segment_index} 段')}}]},{"tag":"markdown","content":${json.encode(markdown)}}]}'
}

pub fn UpdateMessageRequest.http_method_for(msg_type string) http.Method {
	return match msg_type {
		'interactive' { .patch }
		else { .put }
	}
}

pub fn UpdateMessageRequest.delay_card_body(token string, raw_content string) !string {
	if token.trim_space() == '' {
		return error('missing callback token')
	}
	card_content := raw_content.trim_space()
	if card_content == '' {
		return error('missing interactive card content')
	}
	token_json := json.encode(token)
	return '{"token":${token_json},"card":${card_content}}'
}

// ── Stream Content Helpers ──

pub fn StreamBuffer.split_content_runes(content string, limit int) (string, string) {
	runes := content.runes()
	if runes.len <= limit {
		return content, ''
	}
	head_runes := runes[..limit]
	tail_runes := runes[limit..]
	mut head := head_runes.string()
	mut tail := tail_runes.string()
	markers := ['\n\n', '\n### ', '\n## ', '\n- ', '\n* ', '\n1. ', '\n2. ', '\n3. ', '\n• ']
	for marker in markers {
		if idx := head.last_index(marker) {
			if idx > limit / 2 {
				candidate_head := head[..idx].trim_space()
				candidate_tail := (head[idx..] + tail).trim_space()
				if candidate_head != '' && candidate_tail != '' {
					head = candidate_head
					tail = candidate_tail
					break
				}
			}
		}
	}
	return head, tail
}

pub fn StreamBuffer.streaming_preview_markdown(content string) string {
	trimmed := content.trim_space()
	if trimmed == '' {
		return ''
	}
	head, tail := StreamBuffer.split_content_runes(trimmed, stream_buffer_rollover_runes)
	if tail == '' {
		return head
	}
	note := '\n\n_内容过长，预览已截断，完整结果会在结束时自动分段发送。_'
	mut preview := head.trim_space()
	if preview == '' {
		return note.trim_space()
	}
	if (preview + note).runes().len <= stream_buffer_rollover_runes {
		return preview + note
	}
	note_runes := note.runes().len
	head_limit := if stream_buffer_rollover_runes > note_runes {
		stream_buffer_rollover_runes - note_runes
	} else {
		stream_buffer_rollover_runes
	}
	short_head, _ := StreamBuffer.split_content_runes(preview, head_limit)
	return short_head.trim_space() + note
}

pub fn StreamBuffer.render_final_card(markdown string, template_content string) string {
	if template_content.trim_space() == '' {
		return SendMessageRequest.interactive_markdown_card(markdown)
	}
	escaped_json := json.encode(markdown)
	escaped := escaped_json[1..escaped_json.len - 1]
	if template_content.contains('{{content}}') {
		return template_content.replace('{{content}}', escaped)
	}
	return template_content
}

// ── Feishu streaming normalization ──

pub fn SendMessageRequest.normalize_upstream_for_streaming(req upstream.UpstreamSendRequest) upstream.UpstreamSendRequest {
	if req.message_type.trim_space() == 'interactive' {
		return req
	}
	mut normalized := req
	mut markdown := SendMessageRequest.extract_markdown_text(req.content, req.text,
		req.content_fields)
	if markdown.trim_space() == '' {
		markdown = '⚙️ **处理中...**'
	}
	normalized.message_type = 'interactive'
	normalized.content = SendMessageRequest.interactive_markdown_card(markdown)
	normalized.text = ''
	normalized.content_fields = map[string]string{}
	return normalized
}

pub fn SendMessageRequest.normalize_upstream_for_streaming_if_needed(req upstream.UpstreamSendRequest, normalized command.NormalizedCommand) upstream.UpstreamSendRequest {
	if normalized.correlation.stream_id.trim_space() == '' {
		return req
	}
	return SendMessageRequest.normalize_upstream_for_streaming(req)
}

pub fn SendMessageRequest.upstream_request_from_command(normalized command.NormalizedCommand) upstream.UpstreamSendRequest {
	return upstream.UpstreamSendRequest.from_normalized(normalized, 'feishu')
}
