module feishu

import json
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

pub struct UploadImageRequest {
pub:
	app            string
	image_type     string @[json: 'image_type']
	filename       string
	content_type   string @[json: 'content_type']
	data_base64    string @[json: 'data_base64']
	content_length int    @[json: 'content_length']
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

pub fn JsonField.string(obj map[string]json2.Any, key string) string {
	return (obj[key] or { json2.Any('') }).str()
}

pub fn JsonField.map(obj map[string]json2.Any, key string) map[string]json2.Any {
	return (obj[key] or { json2.Any(map[string]json2.Any{}) }).as_map()
}
