module feishu

import config
import executor
import sync
import time
import net.websocket

// ── HTTP Lane Types (shared references) ──

pub struct HttpLane {}

pub struct ControlHttpLane {}

// ── Feishu Protocol Types ──

pub struct RuntimeProtoHeader {
pub mut:
	key   string
	value string
}

pub struct RuntimeProtoFrame {
pub mut:
	seq_id           u64
	log_id           u64
	service          i32
	method           i32
	headers          []RuntimeProtoHeader
	payload_encoding string
	payload_type     string
	payload          []u8
	log_id_str       string
}

// ── Client Config (from websocket handshake) ──

pub struct RuntimeClientConfig {
pub:
	reconnect_interval int @[json: 'ReconnectInterval']
	reconnect_nonce    int @[json: 'ReconnectNonce']
	ping_interval      int @[json: 'PingInterval']
	reconnect_count    int @[json: 'ReconnectCount']
}

pub struct RuntimeWsEndpointData {
pub:
	url           string              @[json: 'URL']
	client_config RuntimeClientConfig @[json: 'ClientConfig']
}

pub struct RuntimeWsEndpointResponse {
pub:
	code int
	msg  string
	data RuntimeWsEndpointData
}

// ── Event Snapshot (per received event) ──

pub struct RuntimeEventSnapshot {
pub:
	seq_id            string
	trace_id          string
	action            string
	event_id          string
	event_kind        string
	event_type        string
	message_id        string
	message_type      string
	chat_id           string
	chat_type         string
	target_type       string
	target            string
	open_message_id   string
	root_id           string
	parent_id         string
	create_time       string
	sender_id         string
	sender_id_type    string
	sender_tenant_key string
	action_tag        string
	action_value      string
	token             string
	received_at       i64
	payload           string
}

// ── Provider Runtime (per-app connection) ──

pub struct ProviderRuntime {
pub mut:
	name                            string
	connected                       bool
	ws_url                          string
	ping_interval_seconds           int
	last_connect_at_unix            i64
	last_disconnect_at_unix         i64
	last_error                      string
	tenant_access_token             string
	tenant_access_token_expire_unix i64
	connect_attempts                i64
	connect_successes               i64
	received_frames                 i64
	acked_events                    i64
	messages_sent                   i64
	send_errors                     i64
	recent_events                   []RuntimeEventSnapshot
}

pub fn ProviderRuntime.new(name string) ProviderRuntime {
	return ProviderRuntime{
		name:          name
		recent_events: []RuntimeEventSnapshot{}
	}
}

// ── ProviderRuntime Methods ──

pub fn (rt &ProviderRuntime) is_connected() bool {
	return rt.connected
}

pub fn (rt &ProviderRuntime) ping_interval_seconds_value() int {
	if rt.ping_interval_seconds > 0 {
		return rt.ping_interval_seconds
	}
	return 5
}

pub fn (rt &ProviderRuntime) app_snapshot(name string, enabled bool, open_base_url string) RuntimeAppSnapshot {
	return rt.app_snapshot_with_source(name, enabled, open_base_url, 'runtime', false, false)
}

pub fn (rt &ProviderRuntime) app_snapshot_with_source(name string, enabled bool, open_base_url string, source string, static_configured bool, dynamic_configured bool) RuntimeAppSnapshot {
	resolved_name := if rt.name.trim_space() != '' { rt.name } else { name }
	return RuntimeAppSnapshot{
		name:                    resolved_name
		source:                  source
		static_configured:       static_configured
		dynamic_configured:      dynamic_configured
		enabled:                 enabled
		configured:              true
		connected:               rt.connected
		open_base_url:           open_base_url
		ws_url:                  rt.ws_url
		ping_interval_seconds:   rt.ping_interval_seconds
		last_connect_at_unix:    rt.last_connect_at_unix
		last_disconnect_at_unix: rt.last_disconnect_at_unix
		last_error:              rt.last_error
		connect_attempts:        rt.connect_attempts
		connect_successes:       rt.connect_successes
		received_frames:         rt.received_frames
		acked_events:            rt.acked_events
		messages_sent:           rt.messages_sent
		send_errors:             rt.send_errors
		recent_events:           rt.recent_events.clone()
	}
}

pub fn (mut rt ProviderRuntime) note_connecting() {
	rt.connect_attempts++
}

pub fn (mut rt ProviderRuntime) note_connected(ws_url string) {
	rt.connected = true
	rt.ws_url = ws_url
	rt.last_connect_at_unix = time.now().unix()
	rt.connect_successes++
	rt.last_error = ''
}

pub fn (mut rt ProviderRuntime) note_disconnected(reason string) {
	rt.connected = false
	rt.last_disconnect_at_unix = time.now().unix()
	rt.last_error = reason
}

pub fn (mut rt ProviderRuntime) note_frame() {
	rt.received_frames++
}

pub fn (mut rt ProviderRuntime) note_ack() {
	rt.acked_events++
}

pub fn (mut rt ProviderRuntime) note_send(ok bool) {
	if ok {
		rt.messages_sent++
	} else {
		rt.send_errors++
	}
}

pub fn (mut rt ProviderRuntime) note_client_config(cfg RuntimeClientConfig) {
	if cfg.ping_interval > 0 {
		rt.ping_interval_seconds = cfg.ping_interval
	}
}

pub fn (mut rt ProviderRuntime) cache_tenant_access_token(token string, expire_unix i64) {
	rt.tenant_access_token = token
	rt.tenant_access_token_expire_unix = expire_unix
}

pub fn (mut rt ProviderRuntime) push_event(snapshot RuntimeEventSnapshot, limit int) {
	mut events := rt.recent_events.clone()
	events << snapshot
	applied_limit := if limit > 0 { limit } else { 20 }
	if events.len > applied_limit {
		events = events[events.len - applied_limit..].clone()
	}
	rt.recent_events = events
}

// ── Stream Buffer ──

pub struct StreamBuffer {
pub:
	message_id string
pub mut:
	app              string
	content          string
	rendered_content string
	last_delta       i64 // ms epoch
	last_flush       i64 // ms epoch
	stream_id        string
	receive_id       string
	receive_id_type  string
	segment_index    int
	sealed           bool
	next_message_id  string
}

// ── Admin Snapshot Types ──

pub struct RuntimeAppSnapshot {
pub:
	name                    string
	source                  string
	static_configured       bool @[json: 'static_configured']
	dynamic_configured      bool @[json: 'dynamic_configured']
	enabled                 bool
	configured              bool
	connected               bool
	open_base_url           string
	ws_url                  string
	ping_interval_seconds   int
	last_connect_at_unix    i64
	last_disconnect_at_unix i64
	last_error              string
	connect_attempts        i64
	connect_successes       i64
	received_frames         i64
	acked_events            i64
	messages_sent           i64
	send_errors             i64
	recent_events           []RuntimeEventSnapshot
}

pub struct RuntimeSnapshot {
pub:
	enabled         bool
	configured      bool
	app_count       int
	connected_count int
	default_app     string
	apps            []RuntimeAppSnapshot
}

pub struct RuntimeChatSnapshot {
pub:
	instance          string
	chat_id           string
	chat_type         string
	target_type       string @[json: 'target_type']
	target            string
	last_event_type   string @[json: 'last_event_type']
	last_message_id   string @[json: 'last_message_id']
	last_message_type string @[json: 'last_message_type']
	last_sender_id    string @[json: 'last_sender_id']
	last_create_time  string @[json: 'last_create_time']
	last_received_at  i64    @[json: 'last_received_at']
	seen_count        int    @[json: 'seen_count']
}

pub struct RuntimeChatsSnapshot {
pub:
	returned_count int
	limit          int
	offset         int
	instance       string
	chat_type      string @[json: 'chat_type']
	chat_id        string @[json: 'chat_id']
	chats          []RuntimeChatSnapshot
}

// ── App-level Feishu State ──

pub struct FeishuState {
pub mut:
	mu                         sync.Mutex
	enabled                    bool
	open_base_url              string
	reconnect_delay_ms         int
	token_refresh_skew_seconds int
	recent_event_limit         int
	static_apps                map[string]config.FeishuAppConfig
	apps                       map[string]config.FeishuAppConfig
	runtime                    map[string]ProviderRuntime
	buffers                    map[string]StreamBuffer
	http_lane                  shared HttpLane
	control_http_lane          shared ControlHttpLane
	http_test_mu               sync.Mutex
	http_test_stub             bool
	http_test_delay_ms         int
	http_test_inflight         int
	http_test_calls            int
	http_test_message_seq      int
	// feishu card bridge
	card_bridge_mu            sync.Mutex
	card_bridge_send_mu       sync.Mutex
	card_bridge_clients       map[string]&websocket.Client                    = map[string]&websocket.Client{}
	card_bridge_pending       map[string]chan executor.FeishuCardBridgeResult = map[string]chan executor.FeishuCardBridgeResult{}
	card_bridge_proxy_pending map[string]chan BridgeProxyResult               = map[string]chan BridgeProxyResult{}
	card_bridge_client_conn   &websocket.Client = unsafe { nil }
	card_bridge_enabled_flag  bool
	card_bridge_ws_url        string
	card_bridge_client_id     string
	card_bridge_token         string
	card_bridge_target_id     string
}
