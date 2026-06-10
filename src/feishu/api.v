module feishu

import encoding.base64
import json
import net.http

// ── Send Message API ──

// resolve_send_message_params resolves and validates send message parameters.
// Returns (receive_id_type, receive_id, msg_type, content, error).
// If validation fails, an error is returned.
pub fn resolve_send_message_params(req SendMessageRequest) !(string, string, string, string) {
	receive_id_type := if req.receive_id_type.trim_space() == '' {
		'chat_id'
	} else {
		req.receive_id_type.trim_space()
	}
	if req.receive_id.trim_space() == '' {
		return error('missing receive_id')
	}
	msg_type := if req.msg_type.trim_space() == '' { 'text' } else { req.msg_type.trim_space() }
	content := SendMessageRequest.build_content(msg_type, req.content, req.text, req.content_fields)!
	return receive_id_type, req.receive_id.trim_space(), msg_type, content
}

// build_send_message_url builds the Feishu send message API URL.
pub fn build_send_message_url(base_url string, receive_id_type string, receive_id string) string {
	if receive_id_type == 'message_id' {
		return '${base_url}/im/v1/messages/${receive_id}/reply'
	}
	return '${base_url}/im/v1/messages?receive_id_type=${receive_id_type}'
}

// build_send_message_payload builds the JSON payload for sending a Feishu message.
pub fn build_send_message_payload(msg_type string, content string, receive_id string, uuid string, receive_id_type string) string {
	if receive_id_type == 'message_id' {
		return json.encode({
			'msg_type': msg_type
			'content':  content
			'uuid':     uuid
		})
	}
	return json.encode({
		'receive_id': receive_id
		'msg_type':   msg_type
		'content':    content
		'uuid':       uuid
	})
}

// ── Update Message API ──

// resolve_update_message_params resolves and validates update message parameters.
// Returns (message_id_type, target, msg_type, content_raw, error).
pub fn resolve_update_message_params(req UpdateMessageRequest) !(string, string, string, string) {
	message_id_type := if req.message_id_type.trim_space() == '' {
		'message_id'
	} else {
		req.message_id_type.trim_space()
	}
	msg_type := if req.msg_type.trim_space() == '' { 'text' } else { req.msg_type.trim_space() }
	target := req.message_id.trim_space()
	if message_id_type == 'message_id' {
		if target == '' {
			return error('missing message_id')
		}
		if msg_type != 'interactive' {
			return error('message_id-based feishu update only supports interactive cards')
		}
	}
	if message_id_type == 'token' && msg_type != 'interactive' {
		return error('token-based feishu delayed update only supports interactive cards')
	}
	return message_id_type, target, msg_type, req.content
}

// build_update_message_request builds the URL, HTTP method and payload for updating a Feishu message.
// Returns (url, method, payload).
pub fn build_update_message_request(base_url string, message_id_type string, target string, msg_type string, content_raw string, uuid string) !(string, http.Method, string) {
	if message_id_type == 'token' {
		payload := UpdateMessageRequest.delay_card_body(target, content_raw)!
		url := '${base_url}/interactive/v1/card/update'
		return url, .post, payload
	} else if message_id_type == 'message_id' {
		content := SendMessageRequest.build_content(msg_type, content_raw, '', map[string]string{})!
		payload := json.encode({
			'msg_type': msg_type
			'content':  content
			'uuid':     uuid
		})
		url := '${base_url}/im/v1/messages/${target}'
		return url, UpdateMessageRequest.http_method_for(msg_type), payload
	}
	return error('unsupported feishu update target type ${message_id_type}')
}

// ── Upload Image API ──

// resolve_upload_image_params resolves and validates upload image parameters.
pub fn resolve_upload_image_params(req UploadImageRequest) !(string, string, string) {
	if req.data_base64 == '' {
		return error('invalid_image_data')
	}
	data := base64.decode_str(req.data_base64)
	if data == '' {
		return error('invalid_image_data')
	}
	if data.bytes().len > max_upload_image_bytes {
		return error('image_too_large')
	}
	image_type := if req.image_type.trim_space() == '' { 'message' } else { req.image_type.trim_space() }
	filename := if req.filename.trim_space() == '' { 'upload.bin' } else { req.filename.trim_space() }
	content_type := if req.content_type.trim_space() == '' { 'application/octet-stream' } else { req.content_type.trim_space() }
	return image_type, filename, content_type
}

// build_upload_image_multipart_config builds the multipart form config for image upload.
pub fn build_upload_image_multipart_config(image_type string, filename string, content_type string, data []u8, token string) http.PostMultipartFormConfig {
	mut header := http.new_header()
	header.set(.authorization, 'Bearer ${token}')
	config := http.PostMultipartFormConfig{
		form: {
			'image_type': image_type
		}
		files: {
			'image': [
				http.FileData{
					filename:     filename
					content_type: content_type
					data:         data.bytestr()
				},
			]
		}
		header: header
	}
	return config
}

// ── Tenant Token API ──

// build_tenant_token_request_body builds the request body for tenant access token.
pub fn build_tenant_token_request_body(app_id string, app_secret string) string {
	return json.encode({
		'app_id':     app_id
		'app_secret': app_secret
	})
}

// parse_tenant_token_response parses the tenant access token response.
pub fn parse_tenant_token_response(body string) !(string, i64) {
	decoded := json.decode(TenantTokenResponse, body)!
	if decoded.code != 0 || decoded.tenant_access_token.trim_space() == '' {
		return error('feishu tenant token error: ${decoded.msg}')
	}
	return decoded.tenant_access_token, i64(decoded.expire)
}
