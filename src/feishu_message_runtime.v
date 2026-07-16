module main

import encoding.base64
import json
import log
import net.http
import feishu

fn (mut hub ProviderRuntimeHub) feishu_runtime_send_message(req feishu.SendMessageRequest) !feishu.SendMessageResult {
	return hub.feishu_native_send_message(req)
}

fn (mut hub ProviderRuntimeHub) feishu_native_send_message(req feishu.SendMessageRequest) !feishu.SendMessageResult {
	app_name := hub.feishu.resolve_app_name(req.app)!
	if !hub.feishu_runtime_ready() {
		return error('feishu gateway is not configured')
	}
	receive_id_type, receive_id, msg_type, content := req.resolve_params()!
	token := hub.feishu_runtime_tenant_access_token(app_name)!
	mut header := http.new_header(key: .content_type, value: 'application/json; charset=utf-8')
	header.add_custom('authorization', 'Bearer ${token}') or {} // safe to ignore: header append on detached request
	url := feishu.SendMessageRequest.api_url(hub.feishu.open_base_url, receive_id_type, receive_id)
	payload := feishu.SendMessageRequest.api_payload(msg_type, content, receive_id, req.uuid,
		receive_id_type)
	log.info('[feishu] 📤 sending message: method=POST url=${url} payload=${payload.len} bytes')
	resp := (&hub.feishu).http_fetch(
		url:    url
		method: .post
		data:   payload
		header: header
	) or {
		hub.feishu.note_send(app_name, false)
		log.error('[feishu] ❌ send fetch failed: ${err}')
		return err
	}
	log.info('[feishu] 📩 send response: status=${resp.status_code} body=${resp.body}')
	if resp.status_code != 200 {
		hub.feishu.note_send(app_name, false)
		return error('feishu message send failed with status ${resp.status_code}: ${resp.body}')
	}
	decoded := json.decode(feishu.SendMessageResponse, resp.body) or {
		hub.feishu.note_send(app_name, false)
		return error('invalid feishu send response: ${err}')
	}
	if decoded.code != 0 {
		hub.feishu.note_send(app_name, false)
		return error('feishu send error: ${decoded.msg}')
	}
	hub.feishu.note_send(app_name, true)
	return feishu.SendMessageResult{
		ok:         true
		message_id: decoded.data.message_id
	}
}

fn (mut hub ProviderRuntimeHub) feishu_runtime_upload_image(req feishu.UploadImageRequest) !feishu.UploadImageResult {
	return hub.feishu_native_upload_image(req)
}

fn (mut hub ProviderRuntimeHub) feishu_native_upload_image(req feishu.UploadImageRequest) !feishu.UploadImageResult {
	if req.content_length > feishu_runtime_max_upload_image_bytes {
		return error('image_too_large')
	}
	data := base64.decode_str(req.data_base64)
	if data == '' {
		return error('invalid_image_data')
	}
	return hub.feishu_native_upload_image_bytes(req, data.bytes())
}

fn (mut hub ProviderRuntimeHub) feishu_runtime_upload_image_bytes(req feishu.UploadImageRequest, data []u8) !feishu.UploadImageResult {
	return hub.feishu_native_upload_image_bytes(req, data)
}

fn (mut hub ProviderRuntimeHub) feishu_native_upload_image_bytes(req feishu.UploadImageRequest, data []u8) !feishu.UploadImageResult {
	app_name := hub.feishu.resolve_app_name(req.app)!
	if data.len == 0 {
		return error('missing_image_data')
	}
	if data.len > feishu_runtime_max_upload_image_bytes {
		return error('image_too_large')
	}
	token := hub.feishu_runtime_tenant_access_token(app_name)!
	image_type := if req.image_type.trim_space() == '' {
		'message'
	} else {
		req.image_type.trim_space()
	}
	filename := if req.filename.trim_space() == '' {
		'upload.bin'
	} else {
		req.filename.trim_space()
	}
	content_type := if req.content_type.trim_space() == '' {
		'application/octet-stream'
	} else {
		req.content_type.trim_space()
	}
	config := feishu.UploadImageRequest.multipart_config(image_type, filename, content_type, data,
		token)
	resp := (&hub.feishu).http_post_multipart_form('${hub.feishu.open_base_url}/im/v1/images',
		config) or { return error('feishu image upload request failed: ${err.msg()}') }
	if resp.status_code < 200 || resp.status_code >= 300 {
		return error('feishu image upload failed with status ${resp.status_code}')
	}
	decoded := json.decode(feishu.UploadImageResponse, resp.body) or {
		return error('invalid_feishu_image_upload_response')
	}
	if decoded.code != 0 || decoded.data.image_key.trim_space() == '' {
		return error('feishu image upload error: code=${decoded.code} detail=${resp.body}')
	}
	return feishu.UploadImageResult{
		ok:        true
		image_key: decoded.data.image_key
	}
}

fn (mut hub ProviderRuntimeHub) feishu_runtime_update_message(req feishu.UpdateMessageRequest) !feishu.SendMessageResult {
	return hub.feishu_native_update_message(req)
}

fn (mut hub ProviderRuntimeHub) feishu_native_update_message(req feishu.UpdateMessageRequest) !feishu.SendMessageResult {
	app_name := hub.feishu.resolve_app_name(req.app)!
	if !hub.feishu_runtime_ready() {
		return error('feishu gateway is not configured')
	}
	message_id_type, target, msg_type, mut content_raw := req.resolve_params()!

	// Support buffer placeholder replacement or auto-append
	if target != '' {
		hub.feishu.mu.@lock()
		if buf := hub.feishu.buffers[target] {
			if content_raw.contains('{{content}}') {
				escaped := buf.content.replace('\\', '\\\\').replace('"', '\\"').replace('\n',
					'\\n')
				content_raw = content_raw.replace('{{content}}', escaped)
				log.info('[feishu] 🧩 replaced {{content}} placeholder')
			}
		}
		hub.feishu.mu.unlock()
	}

	token := hub.feishu_runtime_tenant_access_token(app_name)!
	mut header := http.new_header(key: .content_type, value: 'application/json; charset=utf-8')
	header.add_custom('authorization', 'Bearer ${token}') or {} // safe to ignore: header append on detached request
	url, method, payload := feishu.UpdateMessageRequest.api_request(hub.feishu.open_base_url,
		message_id_type, target, msg_type, content_raw, req.uuid)!
	log.info('[feishu] 📤 sending update: method=${method} url=${url} payload=${payload.len} bytes')
	resp := (&hub.feishu).http_fetch(
		url:    url
		method: method
		data:   payload
		header: header
	) or {
		hub.feishu.note_send(app_name, false)
		log.error('[feishu] ❌ update fetch failed: ${err}')
		return err
	}
	log.info('[feishu] 📩 update response: status=${resp.status_code} body=${resp.body}')
	if resp.status_code != 200 {
		hub.feishu.note_send(app_name, false)
		return error('feishu message update failed with status ${resp.status_code}: ${resp.body}')
	}
	decoded := json.decode(feishu.SendMessageResponse, resp.body) or {
		hub.feishu.note_send(app_name, false)
		return error('invalid feishu update response: ${err}')
	}
	if decoded.code != 0 {
		hub.feishu.note_send(app_name, false)
		return error('feishu update error: ${decoded.msg}')
	}
	hub.feishu.note_send(app_name, true)
	return feishu.SendMessageResult{
		ok:         true
		message_id: if decoded.data.message_id.trim_space() != '' {
			decoded.data.message_id
		} else {
			target
		}
	}
}
