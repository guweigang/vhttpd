module feishu

import upstream

// ── Bridge Protocol Constants ──

pub const card_bridge_request_type = 'feishu_card_callback'
pub const card_bridge_result_type = 'feishu_card_callback_result'
pub const bridge_proxy_request_type = 'feishu_proxy_request'
pub const bridge_proxy_result_type = 'feishu_proxy_result'
pub const bridge_ping_type = 'feishu_bridge_ping'
pub const bridge_pong_type = 'feishu_bridge_pong'

// ── Bridge Protocol Types ──

pub struct BridgeEnvelope {
	pub:
		type_      string @[json: 'type']
		request_id string @[json: 'request_id']
}

pub struct BridgeHeartbeatFrame {
	pub:
		type_      string @[json: 'type']
		request_id string @[json: 'request_id']
		trace_id   string @[json: 'trace_id']
		sent_at    i64    @[json: 'sent_at']
}

pub struct BridgeDispatchRequest {
	pub:
		type_       string @[json: 'type']
		request_id  string @[json: 'request_id']
		trace_id    string @[json: 'trace_id']
		app         string
		event_type  string @[json: 'event_type']
		message_id  string @[json: 'message_id']
		target      string
		target_type string @[json: 'target_type']
		payload     string
		metadata    map[string]string
}

pub struct BridgeGatewayDispatchRequest {
	pub:
		app         string
		trace_id    string @[json: 'trace_id']
		event_type  string @[json: 'event_type']
		message_id  string @[json: 'message_id']
		target      string
		target_type string @[json: 'target_type']
		payload     string
		metadata    map[string]string
}

pub struct BridgeDispatchResult {
	pub:
		type_      string @[json: 'type']
		request_id string @[json: 'request_id']
		status     int
		headers    map[string]string
		body       string
		error      string
}

pub struct BridgeProxyRequest {
	pub:
		type_      string @[json: 'type']
		request_id string @[json: 'request_id']
		action     string
		request    upstream.UpstreamSendRequest
}
