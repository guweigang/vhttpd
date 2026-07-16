module feishu

import crypto.aes
import crypto.cipher
import crypto.sha256
import command
import encoding.base64
import executor
import json
import net.http
import net.urllib
import upstream
import x.json2

// ── Protocol Constants ──

pub const frame_type_control = 0
pub const frame_type_data = 1
pub const header_type = 'type'
pub const header_seq = 'seq'
pub const header_trace = 'trace_id'
pub const header_biz_rt = 'biz_rt'
pub const message_ping = 'ping'
pub const message_pong = 'pong'
pub const message_data = 'data'
pub const message_event = 'event'
pub const message_card = 'card'
pub const max_upload_image_bytes = 10 * 1024 * 1024
pub const stream_buffer_rollover_runes = 4200

// ── Callback / Auth Types ──

pub struct TenantTokenResponse {
pub:
	code                int
	msg                 string
	tenant_access_token string @[json: 'tenant_access_token']
	expire              int
}

pub struct CallbackChallengeResponse {
pub:
	challenge string
}

pub struct CallbackAckResponse {
pub:
	code int
	msg  string
}

// ── Message Types ──

pub struct SendMessageData {
pub:
	message_id string @[json: 'message_id']
}

pub struct UploadImageData {
pub:
	image_key string @[json: 'image_key']
}

pub struct SendMessageResponse {
pub:
	code int
	msg  string
	data SendMessageData
}

pub struct UploadImageResponse {
pub:
	code int
	msg  string
	data UploadImageData
}

pub struct SendMessageRequest {
pub:
	app             string            @[json: 'app']
	receive_id_type string            @[json: 'receive_id_type']
	receive_id      string            @[json: 'receive_id']
	msg_type        string            @[json: 'msg_type']
	content         string            @[json: 'content']
	content_fields  map[string]string @[json: 'content_fields']
	text            string            @[json: 'text']
	uuid            string            @[json: 'uuid']
}

pub struct UpdateMessageRequest {
pub:
	app             string            @[json: 'app']
	message_id      string            @[json: 'message_id']
	message_id_type string            @[json: 'message_id_type']
	msg_type        string            @[json: 'msg_type']
	content         string            @[json: 'content']
	content_fields  map[string]string @[json: 'content_fields']
	text            string            @[json: 'text']
	uuid            string            @[json: 'uuid']
}

pub struct UploadImageRequest {
pub:
	app            string
	image_type     string @[json: 'image_type']
	filename       string
	content_type   string @[json: 'content_type']
	data_base64    string @[json: 'data_base64']
	content_length int    @[json: 'content_length']
}

pub fn SendMessageRequest.from_upstream_request(req upstream.UpstreamSendRequest) SendMessageRequest {
	return SendMessageRequest{
		app:             req.instance
		receive_id_type: req.target_type
		receive_id:      req.target
		msg_type:        req.message_type
		content:         req.content
		content_fields:  req.content_fields.clone()
		text:            req.text
		uuid:            req.uuid
	}
}

pub fn UpdateMessageRequest.from_upstream_request(req upstream.UpstreamSendRequest) UpdateMessageRequest {
	return UpdateMessageRequest{
		app:             req.instance
		message_id:      req.target
		message_id_type: req.target_type
		msg_type:        req.message_type
		content:         req.content
		content_fields:  req.content_fields.clone()
		text:            req.text
		uuid:            req.uuid
	}
}

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

pub fn UploadImageRequest.from_json(body string) !UploadImageRequest {
	return json.decode(UploadImageRequest, body)
}

pub struct TextContent {
pub:
	text string @[json: 'text']
}

pub struct SendMessageResult {
pub:
	ok         bool
	message_id string @[json: 'message_id']
	error      string
}

pub fn (result SendMessageResult) to_upstream_send_result(provider string, instance string) upstream.UpstreamSendResult {
	return upstream.UpstreamSendResult{
		ok:         result.ok
		provider:   provider
		instance:   instance
		message_id: result.message_id
		error:      result.error
	}
}

pub fn (result SendMessageResult) to_upstream_update_result(provider string, instance string) upstream.UpstreamUpdateResult {
	return upstream.UpstreamUpdateResult{
		ok:         result.ok
		provider:   provider
		instance:   instance
		message_id: result.message_id
		error:      result.error
	}
}

pub struct UploadImageResult {
pub:
	ok        bool
	image_key string @[json: 'image_key']
	error     string
}

pub struct WsResponsePayload {
pub:
	code    int
	headers map[string]string
	data    string
}

// ── JSON Helpers ──

pub struct JsonField {}

pub fn json_field_string(obj map[string]json2.Any, key string) string {
	return JsonField.string(obj, key)
}

pub fn json_map_field(obj map[string]json2.Any, key string) map[string]json2.Any {
	return JsonField.map(obj, key)
}

pub fn JsonField.string(obj map[string]json2.Any, key string) string {
	return (obj[key] or { json2.Any('') }).str()
}

pub fn JsonField.map(obj map[string]json2.Any, key string) map[string]json2.Any {
	return (obj[key] or { json2.Any(map[string]json2.Any{}) }).as_map()
}

// ── Message Content Building ──

pub fn build_message_content(msg_type string, raw_content string, text string, content_fields map[string]string) !string {
	return SendMessageRequest.build_content(msg_type, raw_content, text, content_fields)
}

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

pub fn extract_markdown_text(raw_content string, text string, content_fields map[string]string) string {
	return SendMessageRequest.extract_markdown_text(raw_content, text, content_fields)
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

pub fn interactive_markdown_card(markdown string) string {
	return SendMessageRequest.interactive_markdown_card(markdown)
}

pub fn SendMessageRequest.interactive_markdown_card(markdown string) string {
	return '{"elements":[{"tag":"markdown","content":${json.encode(markdown)}}]}'
}

pub fn streaming_card(markdown string, segment_index int) string {
	return SendMessageRequest.streaming_card(markdown, segment_index)
}

pub fn SendMessageRequest.streaming_card(markdown string, segment_index int) string {
	if segment_index <= 1 {
		return SendMessageRequest.interactive_markdown_card(markdown)
	}
	return '{"elements":[{"tag":"note","elements":[{"tag":"plain_text","content":${json.encode('继续输出 · 第 ${segment_index} 段')}}]},{"tag":"markdown","content":${json.encode(markdown)}}]}'
}

pub fn update_http_method(msg_type string) http.Method {
	return UpdateMessageRequest.http_method_for(msg_type)
}

pub fn UpdateMessageRequest.http_method_for(msg_type string) http.Method {
	return match msg_type {
		'interactive' { .patch }
		else { .put }
	}
}

pub fn delay_update_card_body(token string, raw_content string) !string {
	return UpdateMessageRequest.delay_card_body(token, raw_content)
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

// ── Endpoint URL Helpers ──

pub fn normalize_open_base(raw string) string {
	return RuntimeWsEndpointData.normalize_open_base(raw)
}

pub fn RuntimeWsEndpointData.normalize_open_base(raw string) string {
	mut base := raw.trim_space()
	if base == '' {
		base = 'https://open.feishu.cn/open-apis'
	}
	for base.len > 1 && base.ends_with('/') {
		base = base[..base.len - 1]
	}
	return base
}

pub fn root_base(base string) string {
	return RuntimeWsEndpointData.root_base(base)
}

pub fn ws_endpoint_urls(base string) []string {
	return RuntimeWsEndpointData.endpoint_urls(base)
}

pub fn RuntimeWsEndpointData.root_base(base string) string {
	mut trimmed := RuntimeWsEndpointData.normalize_open_base(base)
	if trimmed.ends_with('/open-apis') {
		trimmed = trimmed[..trimmed.len - '/open-apis'.len]
	}
	return trimmed
}

pub fn RuntimeWsEndpointData.endpoint_urls(base string) []string {
	primary := '${RuntimeWsEndpointData.normalize_open_base(base)}/callback/ws/endpoint'
	fallback := '${RuntimeWsEndpointData.root_base(base)}/callback/ws/endpoint'
	if fallback == primary {
		return [primary]
	}
	return [primary, fallback]
}

pub fn ws_endpoint_body(app_id string, app_secret string) string {
	return RuntimeWsEndpointData.request_body(app_id, app_secret)
}

pub fn RuntimeWsEndpointData.request_body(app_id string, app_secret string) string {
	return json.encode({
		'AppID':     app_id
		'AppSecret': app_secret
	})
}

// ── Callback Crypto ──

pub fn callback_challenge(payload string) string {
	return CallbackChallengeResponse.challenge(payload)
}

pub fn CallbackChallengeResponse.challenge(payload string) string {
	parsed := json2.decode[json2.Any](payload) or { return '' }
	root := parsed.as_map()
	if JsonField.string(root, 'type') != 'url_verification' {
		return ''
	}
	return JsonField.string(root, 'challenge')
}

pub fn pkcs7_unpad(data []u8) ![]u8 {
	return CallbackChallengeResponse.pkcs7_unpad(data)
}

pub fn CallbackChallengeResponse.pkcs7_unpad(data []u8) ![]u8 {
	if data.len == 0 {
		return error('empty encrypted payload')
	}
	padding := int(data[data.len - 1])
	if padding <= 0 || padding > aes.block_size || padding > data.len {
		return error('invalid pkcs7 padding')
	}
	for i in data.len - padding .. data.len {
		if int(data[i]) != padding {
			return error('invalid pkcs7 padding')
		}
	}
	return data[..data.len - padding].clone()
}

pub fn callback_signature_valid(headers map[string]string, encrypt_key string, payload string) bool {
	return CallbackChallengeResponse.signature_valid(headers, encrypt_key, payload)
}

pub fn CallbackChallengeResponse.signature_valid(headers map[string]string, encrypt_key string, payload string) bool {
	mut signature := (headers['x-lark-signature'] or { '' }).trim_space().to_lower()
	if signature == '' {
		signature = (headers['x-lark-request-signature'] or { '' }).trim_space().to_lower()
	}
	if signature == '' {
		return encrypt_key.trim_space() == ''
	}
	timestamp := (headers['x-lark-request-timestamp'] or { '' }).trim_space()
	nonce := (headers['x-lark-request-nonce'] or { '' }).trim_space()
	if timestamp == '' || nonce == '' || encrypt_key.trim_space() == '' {
		return false
	}
	expected := sha256.sum('${timestamp}${nonce}${encrypt_key}${payload}'.bytes()).hex().to_lower()
	return signature == expected
}

pub fn callback_decrypt_payload(encrypt_key string, payload string) !string {
	return CallbackChallengeResponse.decrypt_payload(encrypt_key, payload)
}

pub fn CallbackChallengeResponse.decrypt_payload(encrypt_key string, payload string) !string {
	if encrypt_key.trim_space() == '' {
		return payload
	}
	parsed := json2.decode[json2.Any](payload) or { return payload }
	root := parsed.as_map()
	encrypted := JsonField.string(root, 'encrypt')
	if encrypted == '' {
		return payload
	}
	ciphertext := base64.decode(encrypted)
	if ciphertext.len < aes.block_size || ciphertext.len % aes.block_size != 0 {
		return error('invalid feishu encrypted payload length')
	}
	key := sha256.sum(encrypt_key.bytes())
	iv := key[..aes.block_size].clone()
	mut block := aes.new_cipher(key)
	mut mode := cipher.new_cbc(block, iv)
	mut plaintext := []u8{len: ciphertext.len}
	mode.decrypt_blocks(mut plaintext, ciphertext)
	unpadded := CallbackChallengeResponse.pkcs7_unpad(plaintext)!
	return unpadded.bytestr()
}

// ── Protobuf Encoding ──

pub fn varint_encode(mut out []u8, value u64) {
	RuntimeProtoFrame.varint_encode(mut out, value)
}

pub fn RuntimeProtoFrame.varint_encode(mut out []u8, value u64) {
	mut current := value
	for {
		if (current & ~u64(0x7f)) == 0 {
			out << u8(current)
			return
		}
		out << u8((current & 0x7f) | 0x80)
		current >>= 7
	}
}

pub fn encode_field_key(mut out []u8, field_number int, wire_type int) {
	RuntimeProtoFrame.encode_field_key(mut out, field_number, wire_type)
}

pub fn RuntimeProtoFrame.encode_field_key(mut out []u8, field_number int, wire_type int) {
	RuntimeProtoFrame.varint_encode(mut out, (u64(field_number) << 3) | u64(wire_type))
}

pub fn encode_bytes_field(mut out []u8, field_number int, payload []u8) {
	RuntimeProtoFrame.encode_bytes_field(mut out, field_number, payload)
}

pub fn RuntimeProtoFrame.encode_bytes_field(mut out []u8, field_number int, payload []u8) {
	RuntimeProtoFrame.encode_field_key(mut out, field_number, 2)
	RuntimeProtoFrame.varint_encode(mut out, u64(payload.len))
	out << payload
}

pub fn encode_string_field(mut out []u8, field_number int, payload string) {
	RuntimeProtoFrame.encode_string_field(mut out, field_number, payload)
}

pub fn RuntimeProtoFrame.encode_string_field(mut out []u8, field_number int, payload string) {
	RuntimeProtoFrame.encode_bytes_field(mut out, field_number, payload.bytes())
}

pub fn proto_header_encode(header RuntimeProtoHeader) []u8 {
	return header.encode()
}

pub fn (header RuntimeProtoHeader) encode() []u8 {
	mut out := []u8{}
	if header.key != '' {
		RuntimeProtoFrame.encode_string_field(mut out, 1, header.key)
	}
	if header.value != '' {
		RuntimeProtoFrame.encode_string_field(mut out, 2, header.value)
	}
	return out
}

pub fn proto_frame_encode(frame RuntimeProtoFrame) []u8 {
	return frame.encode()
}

pub fn (frame RuntimeProtoFrame) encode() []u8 {
	mut out := []u8{}
	if frame.seq_id > 0 {
		RuntimeProtoFrame.encode_field_key(mut out, 1, 0)
		RuntimeProtoFrame.varint_encode(mut out, frame.seq_id)
	}
	if frame.log_id > 0 {
		RuntimeProtoFrame.encode_field_key(mut out, 2, 0)
		RuntimeProtoFrame.varint_encode(mut out, frame.log_id)
	}
	if frame.service != 0 {
		RuntimeProtoFrame.encode_field_key(mut out, 3, 0)
		RuntimeProtoFrame.varint_encode(mut out, u64(frame.service))
	}
	RuntimeProtoFrame.encode_field_key(mut out, 4, 0)
	RuntimeProtoFrame.varint_encode(mut out, u64(frame.method))

	for header in frame.headers {
		encoded := header.encode()
		if encoded.len > 0 {
			RuntimeProtoFrame.encode_bytes_field(mut out, 5, encoded)
		}
	}
	if frame.payload_encoding != '' {
		RuntimeProtoFrame.encode_string_field(mut out, 6, frame.payload_encoding)
	}
	if frame.payload_type != '' {
		RuntimeProtoFrame.encode_string_field(mut out, 7, frame.payload_type)
	}
	if frame.payload.len > 0 {
		RuntimeProtoFrame.encode_bytes_field(mut out, 8, frame.payload)
	}
	if frame.log_id_str != '' {
		RuntimeProtoFrame.encode_string_field(mut out, 9, frame.log_id_str)
	}
	return out
}

// ── Protobuf Decoding ──

pub fn varint_decode(buf []u8, start int) !(u64, int) {
	return RuntimeProtoFrame.varint_decode(buf, start)
}

pub fn RuntimeProtoFrame.varint_decode(buf []u8, start int) !(u64, int) {
	mut value := u64(0)
	mut shift := 0
	mut idx := start
	for idx < buf.len {
		b := buf[idx]
		value |= u64(b & 0x7f) << shift
		idx++
		if (b & 0x80) == 0 {
			return value, idx
		}
		shift += 7
		if shift >= 64 {
			return error('protobuf varint overflow')
		}
	}
	return error('unexpected end of protobuf varint')
}

pub fn skip_wire(buf []u8, start int, wire_type int) !int {
	return RuntimeProtoFrame.skip_wire(buf, start, wire_type)
}

pub fn RuntimeProtoFrame.skip_wire(buf []u8, start int, wire_type int) !int {
	match wire_type {
		0 {
			_, next := RuntimeProtoFrame.varint_decode(buf, start)!
			return next
		}
		2 {
			length, next := RuntimeProtoFrame.varint_decode(buf, start)!
			end := next + int(length)
			if end > buf.len {
				return error('protobuf length exceeds payload')
			}
			return end
		}
		else {
			return error('unsupported protobuf wire type ${wire_type}')
		}
	}
}

pub fn proto_header_decode(buf []u8) !RuntimeProtoHeader {
	return RuntimeProtoHeader.decode(buf)
}

pub fn RuntimeProtoHeader.decode(buf []u8) !RuntimeProtoHeader {
	mut out := RuntimeProtoHeader{}
	mut idx := 0
	for idx < buf.len {
		key, next := RuntimeProtoFrame.varint_decode(buf, idx)!
		idx = next
		field_number := int(key >> 3)
		wire_type := int(key & 0x07)
		if wire_type != 2 {
			idx = RuntimeProtoFrame.skip_wire(buf, idx, wire_type)!
			continue
		}
		length, next_len := RuntimeProtoFrame.varint_decode(buf, idx)!
		start := next_len
		end := start + int(length)
		if end > buf.len {
			return error('protobuf header payload truncated')
		}
		value := buf[start..end].bytestr()
		match field_number {
			1 { out.key = value }
			2 { out.value = value }
			else {}
		}

		idx = end
	}
	return out
}

pub fn proto_frame_decode(buf []u8) !RuntimeProtoFrame {
	return RuntimeProtoFrame.decode(buf)
}

pub fn RuntimeProtoFrame.decode(buf []u8) !RuntimeProtoFrame {
	mut out := RuntimeProtoFrame{}
	mut idx := 0
	for idx < buf.len {
		key, next := RuntimeProtoFrame.varint_decode(buf, idx)!
		idx = next
		field_number := int(key >> 3)
		wire_type := int(key & 0x07)
		match field_number {
			1, 2, 3, 4 {
				value, next_val := RuntimeProtoFrame.varint_decode(buf, idx)!
				match field_number {
					1 { out.seq_id = value }
					2 { out.log_id = value }
					3 { out.service = i32(value) }
					4 { out.method = i32(value) }
					else {}
				}

				idx = next_val
			}
			5, 6, 7, 8, 9 {
				if wire_type != 2 {
					return error('unexpected protobuf wire type ${wire_type} for field ${field_number}')
				}
				length, next_len := RuntimeProtoFrame.varint_decode(buf, idx)!
				start := next_len
				end := start + int(length)
				if end > buf.len {
					return error('protobuf field exceeds payload')
				}
				match field_number {
					5 {
						header := RuntimeProtoHeader.decode(buf[start..end])!
						out.headers << header
					}
					6 {
						out.payload_encoding = buf[start..end].bytestr()
					}
					7 {
						out.payload_type = buf[start..end].bytestr()
					}
					8 {
						out.payload = buf[start..end].clone()
					}
					9 {
						out.log_id_str = buf[start..end].bytestr()
					}
					else {}
				}

				idx = end
			}
			else {
				idx = RuntimeProtoFrame.skip_wire(buf, idx, wire_type)!
			}
		}
	}
	return out
}

pub fn header_map(headers []RuntimeProtoHeader) map[string]string {
	return RuntimeProtoHeader.to_map(headers)
}

pub fn RuntimeProtoHeader.to_map(headers []RuntimeProtoHeader) map[string]string {
	mut out := map[string]string{}
	for header in headers {
		if header.key == '' {
			continue
		}
		out[header.key] = header.value
	}
	return out
}

// ── Event Summary ──

pub fn event_summary(payload string) executor.FeishuRuntimeEventSummary {
	return RuntimeEventSnapshot.summary_from_payload(payload)
}

pub fn RuntimeEventSnapshot.summary_from_payload(payload string) executor.FeishuRuntimeEventSummary {
	parsed := json2.decode[json2.Any](payload) or { return executor.FeishuRuntimeEventSummary{} }
	root := parsed.as_map()
	h := json_map_field(root, 'header')
	event := json_map_field(root, 'event')
	context := json_map_field(root, 'context')
	operator := json_map_field(root, 'operator')
	message := json_map_field(event, 'message')
	sender := json_map_field(event, 'sender')
	sender_id := json_map_field(sender, 'sender_id')
	mut action := json_map_field(event, 'action')
	if action.len == 0 {
		action = json_map_field(root, 'action')
	}
	mut operator_id_type := ''
	mut operator_id_value := ''
	for key, value in operator {
		candidate := value.str()
		if candidate == '' {
			continue
		}
		operator_id_type = key
		operator_id_value = candidate
		break
	}
	mut sender_id_type := ''
	mut sender_id_value := ''
	for key, value in sender_id {
		candidate := value.str()
		if candidate == '' {
			continue
		}
		sender_id_type = key
		sender_id_value = candidate
		break
	}
	action_value := if action_value_any := action['value'] {
		action_value_any.str()
	} else {
		''
	}
	open_message_id := if json_field_string(event, 'open_message_id') != '' {
		json_field_string(event, 'open_message_id')
	} else if json_field_string(context, 'open_message_id') != '' {
		json_field_string(context, 'open_message_id')
	} else {
		json_field_string(action, 'open_message_id')
	}
	mut event_kind := 'event'
	if message.len > 0 || json_field_string(message, 'message_id') != '' {
		event_kind = 'message'
	}
	if action.len > 0 || json_field_string(action, 'tag') != '' {
		event_kind = 'action'
	}
	mut target_type := ''
	mut target := ''
	chat_id := json_field_string(message, 'chat_id')
	if chat_id != '' {
		target_type = 'chat_id'
		target = chat_id
	} else if open_message_id != '' {
		target_type = 'open_message_id'
		target = open_message_id
	}
	return executor.FeishuRuntimeEventSummary{
		event_id:          json_field_string(h, 'event_id')
		event_kind:        event_kind
		event_type:        json_field_string(h, 'event_type')
		message_id:        json_field_string(message, 'message_id')
		message_type:      json_field_string(message, 'message_type')
		chat_id:           chat_id
		chat_type:         json_field_string(message, 'chat_type')
		target_type:       target_type
		target:            target
		open_message_id:   open_message_id
		root_id:           json_field_string(message, 'root_id')
		parent_id:         json_field_string(message, 'parent_id')
		create_time:       json_field_string(message, 'create_time')
		sender_id:         if sender_id_value != '' { sender_id_value } else { operator_id_value }
		sender_id_type:    if sender_id_type != '' { sender_id_type } else { operator_id_type }
		sender_tenant_key: if json_field_string(root, 'tenant_key') != '' {
			json_field_string(root, 'tenant_key')
		} else {
			json_field_string(sender, 'tenant_key')
		}
		action_tag:        json_field_string(action, 'tag')
		action_value:      action_value
		token:             json_field_string(root, 'token')
	}
}

pub fn should_dispatch_upstream(summary executor.FeishuRuntimeEventSummary) bool {
	return RuntimeEventSnapshot.should_dispatch_upstream(summary)
}

pub fn RuntimeEventSnapshot.should_dispatch_upstream(summary executor.FeishuRuntimeEventSummary) bool {
	if summary.event_type == 'im.message.message_read_v1' {
		return false
	}
	return true
}

// ── Frame Helpers ──

pub fn clone_headers_with_type(frame RuntimeProtoFrame, next_type string) []RuntimeProtoHeader {
	return frame.clone_headers_with_type(next_type)
}

pub fn (frame RuntimeProtoFrame) clone_headers_with_type(next_type string) []RuntimeProtoHeader {
	mut out_headers := []RuntimeProtoHeader{}
	mut found_type := false
	for header in frame.headers {
		if header.key == header_type {
			found_type = true
			out_headers << RuntimeProtoHeader{
				key:   header.key
				value: next_type
			}
			continue
		}
		out_headers << RuntimeProtoHeader{
			key:   header.key
			value: header.value
		}
	}
	if !found_type {
		out_headers << RuntimeProtoHeader{
			key:   header_type
			value: next_type
		}
	}
	return out_headers
}

pub fn build_pong(frame RuntimeProtoFrame) RuntimeProtoFrame {
	return frame.pong()
}

pub fn (frame RuntimeProtoFrame) pong() RuntimeProtoFrame {
	return RuntimeProtoFrame{
		seq_id:           frame.seq_id
		log_id:           frame.log_id
		service:          frame.service
		method:           3
		headers:          frame.clone_headers_with_type(message_pong)
		payload_encoding: frame.payload_encoding
		payload_type:     frame.payload_type
		payload:          frame.payload.clone()
		log_id_str:       frame.log_id_str
	}
}

pub fn headers_to_type(headers []RuntimeProtoHeader) string {
	return RuntimeProtoHeader.message_type(headers)
}

pub fn RuntimeProtoHeader.message_type(headers []RuntimeProtoHeader) string {
	for header in headers {
		if header.key == header_type && header.value.trim_space() != '' {
			return header.value
		}
	}
	return message_data
}

pub fn build_ack(frame RuntimeProtoFrame, status int, headers_ map[string]string, data string) RuntimeProtoFrame {
	return frame.ack(status, headers_, data)
}

pub fn (frame RuntimeProtoFrame) ack(status int, headers_ map[string]string, data string) RuntimeProtoFrame {
	mut out_headers := frame.clone_headers_with_type(RuntimeProtoHeader.message_type(frame.headers))
	mut found_biz_rt := false
	for header in out_headers {
		if header.key == header_biz_rt {
			found_biz_rt = true
		}
	}
	if found_biz_rt {
		for i, header in out_headers {
			if header.key == header_biz_rt {
				out_headers[i].value = '0'
			}
		}
	} else {
		out_headers << RuntimeProtoHeader{
			key:   header_biz_rt
			value: '0'
		}
	}
	payload := json.encode(WsResponsePayload{
		code:    if status > 0 { status } else { 200 }
		headers: headers_.clone()
		data:    data
	})
	return RuntimeProtoFrame{
		seq_id:           frame.seq_id
		log_id:           frame.log_id
		service:          frame.service
		method:           frame_type_data
		headers:          out_headers
		payload_encoding: 'json'
		payload_type:     'application/json'
		payload:          payload.bytes()
		log_id_str:       frame.log_id_str
	}
}

pub fn ws_url_service_id(ws_url string) i32 {
	return RuntimeProtoFrame.service_id_from_ws_url(ws_url)
}

pub fn RuntimeProtoFrame.service_id_from_ws_url(ws_url string) i32 {
	parsed := urllib.parse(ws_url) or { return 0 }
	service_id := (parsed.query().get('service_id') or { '' }).trim_space()
	if service_id == '' {
		return 0
	}
	return service_id.int()
}

pub fn build_client_ping(service_id i32) RuntimeProtoFrame {
	return RuntimeProtoFrame.client_ping(service_id)
}

pub fn RuntimeProtoFrame.client_ping(service_id i32) RuntimeProtoFrame {
	mut headers := []RuntimeProtoHeader{}
	headers << RuntimeProtoHeader{
		key:   header_type
		value: message_ping
	}
	return RuntimeProtoFrame{
		service: service_id
		method:  2
		headers: headers
	}
}

// ── Stream Content Helpers ──

pub fn split_content_runes(content string, limit int) (string, string) {
	return StreamBuffer.split_content_runes(content, limit)
}

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

pub fn streaming_preview_markdown(content string) string {
	return StreamBuffer.streaming_preview_markdown(content)
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

pub fn render_final_card(markdown string, template_content string) string {
	return StreamBuffer.render_final_card(markdown, template_content)
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
