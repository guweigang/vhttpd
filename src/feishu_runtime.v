module main
import config
import feishu

import json
import encoding.base64
import net.http
import net.websocket
import time
import veb
import x.json2
import log
import executor

@[markused]
const feishu_runtime_frame_type_control = feishu.frame_type_control
const feishu_runtime_frame_type_data = feishu.frame_type_data
const feishu_runtime_header_type = feishu.header_type
const feishu_runtime_header_seq = feishu.header_seq
const feishu_runtime_header_trace = feishu.header_trace
const feishu_runtime_header_biz_rt = feishu.header_biz_rt
const feishu_runtime_message_ping = feishu.message_ping
const feishu_runtime_message_pong = feishu.message_pong
const feishu_runtime_message_data = feishu.message_data
const feishu_runtime_message_event = feishu.message_event
const feishu_runtime_message_card = feishu.message_card
const feishu_runtime_max_upload_image_bytes = feishu.max_upload_image_bytes

type FeishuHttpLane = feishu.HttpLane

type FeishuControlHttpLane = feishu.ControlHttpLane

type FeishuRuntimeProtoHeader = feishu.RuntimeProtoHeader

type FeishuRuntimeProtoFrame = feishu.RuntimeProtoFrame

type FeishuRuntimeClientConfig = feishu.RuntimeClientConfig

type FeishuRuntimeWsEndpointData = feishu.RuntimeWsEndpointData

type FeishuRuntimeWsEndpointResponse = feishu.RuntimeWsEndpointResponse

type FeishuRuntimeTenantTokenResponse = feishu.TenantTokenResponse

type FeishuRuntimeSendMessageData = feishu.SendMessageData

type FeishuRuntimeUploadImageData = feishu.UploadImageData

type FeishuRuntimeSendMessageResponse = feishu.SendMessageResponse

type FeishuRuntimeUploadImageResponse = feishu.UploadImageResponse

type FeishuRuntimeEventSnapshot = feishu.RuntimeEventSnapshot

type FeishuProviderRuntime = feishu.ProviderRuntime

fn new_feishu_provider_runtime(name string) FeishuProviderRuntime {
	return feishu.new_provider_runtime(name)
}

type FeishuStreamBuffer = feishu.StreamBuffer

const feishu_stream_buffer_rollover_runes = feishu.stream_buffer_rollover_runes

type FeishuRuntimeAppSnapshot = feishu.RuntimeAppSnapshot

type FeishuRuntimeSnapshot = feishu.RuntimeSnapshot

type FeishuRuntimeChatSnapshot = feishu.RuntimeChatSnapshot

type FeishuRuntimeChatsSnapshot = feishu.RuntimeChatsSnapshot

type FeishuRuntimeSendMessageRequest = feishu.SendMessageRequest

type FeishuRuntimeUpdateMessageRequest = feishu.UpdateMessageRequest

type FeishuRuntimeUploadImageRequest = feishu.UploadImageRequest

type FeishuRuntimeTextContent = feishu.TextContent

type FeishuCallbackChallengeResponse = feishu.CallbackChallengeResponse

type FeishuCallbackAckResponse = feishu.CallbackAckResponse

type FeishuRuntimeSendMessageResult = feishu.SendMessageResult

type FeishuRuntimeUploadImageResult = feishu.UploadImageResult

fn (mut app App) feishu_runtime_http_test_enter() int {
	app.feishu.http_test_mu.@lock()
	app.feishu.http_test_inflight++
	app.feishu.http_test_calls++
	delay_ms := app.feishu.http_test_delay_ms
	app.feishu.http_test_mu.unlock()
	return delay_ms
}

fn (mut app App) feishu_runtime_http_test_leave() {
	app.feishu.http_test_mu.@lock()
	if app.feishu.http_test_inflight > 0 {
		app.feishu.http_test_inflight--
	}
	app.feishu.http_test_mu.unlock()
}

fn (mut app App) feishu_runtime_http_test_next_message_id() string {
	app.feishu.http_test_mu.@lock()
	app.feishu.http_test_message_seq++
	id := app.feishu.http_test_message_seq
	app.feishu.http_test_mu.unlock()
	return 'om_test_${id}'
}

fn (mut app App) feishu_runtime_http_test_next_reply_message_id() string {
	app.feishu.http_test_mu.@lock()
	app.feishu.http_test_message_seq++
	id := app.feishu.http_test_message_seq
	app.feishu.http_test_mu.unlock()
	return 'om_reply_${id}'
}

fn (mut app App) feishu_runtime_http_test_fetch(cfg http.FetchConfig) !http.Response {
	delay_ms := app.feishu_runtime_http_test_enter()
	defer {
		app.feishu_runtime_http_test_leave()
	}
	if delay_ms > 0 {
		time.sleep(time.Duration(delay_ms) * time.millisecond)
	}
	if cfg.url.contains('/auth/v3/tenant_access_token/internal') {
		return http.Response{
			status_code: 200
			body:        '{"code":0,"msg":"ok","tenant_access_token":"tenant_test_token","expire":7200}'
		}
	}
	if cfg.url.contains('/im/v1/messages/') && cfg.url.contains('/reply') {
		return http.Response{
			status_code: 200
			body:        '{"code":0,"msg":"ok","data":{"message_id":"${app.feishu_runtime_http_test_next_reply_message_id()}"}}'
		}
	}
	if cfg.url.contains('/im/v1/messages?receive_id_type=') {
		return http.Response{
			status_code: 200
			body:        '{"code":0,"msg":"ok","data":{"message_id":"${app.feishu_runtime_http_test_next_message_id()}"}}'
		}
	}
	if cfg.url.contains('/im/v1/messages/') || cfg.url.contains('/interactive/v1/card/update') {
		return http.Response{
			status_code: 200
			body:        '{"code":0,"msg":"ok","data":{"message_id":"om_updated"}}'
		}
	}
	if cfg.url.contains('/ws/v2') || cfg.url.contains('/event/v2') {
		return http.Response{
			status_code: 200
			body:        '{"code":0,"msg":"ok","data":{"url":"wss://example.test/ws","client_config":{"ReconnectInterval":5,"ReconnectNonce":1,"PingInterval":15,"ReconnectCount":0}}}'
		}
	}
	return http.Response{
		status_code: 200
		body:        '{"code":0,"msg":"ok"}'
	}
}

fn (mut app App) feishu_runtime_http_test_post_multipart_form(url string, _ http.PostMultipartFormConfig) !http.Response {
	delay_ms := app.feishu_runtime_http_test_enter()
	defer {
		app.feishu_runtime_http_test_leave()
	}
	if delay_ms > 0 {
		time.sleep(time.Duration(delay_ms) * time.millisecond)
	}
	if url.contains('/im/v1/images') {
		return http.Response{
			status_code: 200
			body:        '{"code":0,"msg":"ok","data":{"image_key":"img_test_1"}}'
		}
	}
	return http.Response{
		status_code: 200
		body:        '{"code":0,"msg":"ok"}'
	}
}

fn feishu_runtime_http_fetch_locked(app &App, cfg http.FetchConfig) !http.Response {
	mut app_mut := unsafe { &App(app) }
	mut resp := http.Response{}
	mut fetch_err := ''
	lock app_mut.feishu.http_lane {
		$if test {
			if app_mut.feishu.http_test_stub {
				resp = app_mut.feishu_runtime_http_test_fetch(cfg) or {
					fetch_err = err.msg()
					http.Response{}
				}
			} else {
				resp = http.fetch(cfg) or {
					fetch_err = err.msg()
					http.Response{}
				}
			}
		} $else {
			resp = http.fetch(cfg) or {
				fetch_err = err.msg()
				http.Response{}
			}
		}
	}
	if fetch_err != '' {
		return error(fetch_err)
	}
	return resp
}

fn (mut app App) feishu_runtime_http_fetch(cfg http.FetchConfig) !http.Response {
	return feishu_runtime_http_fetch_locked(&app, cfg)
}

fn feishu_runtime_control_http_fetch_locked(app &App, cfg http.FetchConfig) !http.Response {
	mut app_mut := unsafe { &App(app) }
	mut resp := http.Response{}
	mut fetch_err := ''
	lock app_mut.feishu.control_http_lane {
		$if test {
			if app_mut.feishu.http_test_stub {
				resp = app_mut.feishu_runtime_http_test_fetch(cfg) or {
					fetch_err = err.msg()
					http.Response{}
				}
			} else {
				resp = http.fetch(cfg) or {
					fetch_err = err.msg()
					http.Response{}
				}
			}
		} $else {
			resp = http.fetch(cfg) or {
				fetch_err = err.msg()
				http.Response{}
			}
		}
	}
	if fetch_err != '' {
		return error(fetch_err)
	}
	return resp
}

fn (mut app App) feishu_runtime_control_http_fetch(cfg http.FetchConfig) !http.Response {
	return feishu_runtime_control_http_fetch_locked(&app, cfg)
}

fn feishu_runtime_http_post_multipart_form_locked(app &App, url string, cfg http.PostMultipartFormConfig) !http.Response {
	mut app_mut := unsafe { &App(app) }
	mut resp := http.Response{}
	mut fetch_err := ''
	lock app_mut.feishu.http_lane {
		$if test {
			if app_mut.feishu.http_test_stub {
				resp = app_mut.feishu_runtime_http_test_post_multipart_form(url, cfg) or {
					fetch_err = err.msg()
					http.Response{}
				}
			} else {
				resp = http.post_multipart_form(url, cfg) or {
					fetch_err = err.msg()
					http.Response{}
				}
			}
		} $else {
			resp = http.post_multipart_form(url, cfg) or {
				fetch_err = err.msg()
				http.Response{}
			}
		}
	}
	if fetch_err != '' {
		return error(fetch_err)
	}
	return resp
}

fn (mut app App) feishu_runtime_http_post_multipart_form(url string, cfg http.PostMultipartFormConfig) !http.Response {
	return feishu_runtime_http_post_multipart_form_locked(&app, url, cfg)
}

// FeishuRuntimeEventSummary is executor.FeishuRuntimeEventSummary (used directly)

type FeishuRuntimeWsResponsePayload = feishu.WsResponsePayload

fn feishu_runtime_json_field_string(obj map[string]json2.Any, key string) string {
	return feishu.json_field_string(obj, key)
}

fn feishu_runtime_json_map_field(obj map[string]json2.Any, key string) map[string]json2.Any {
	return feishu.json_map_field(obj, key)
}

fn feishu_runtime_build_message_content(msg_type string, raw_content string, text string, content_fields map[string]string) !string {
	return feishu.build_message_content(msg_type, raw_content, text, content_fields)
}

fn feishu_runtime_extract_markdown_text(raw_content string, text string, content_fields map[string]string) string {
	return feishu.extract_markdown_text(raw_content, text, content_fields)
}

fn feishu_runtime_interactive_markdown_card(markdown string) string {
	return feishu.interactive_markdown_card(markdown)
}

fn feishu_runtime_streaming_card(markdown string, segment_index int) string {
	return feishu.streaming_card(markdown, segment_index)
}

fn feishu_runtime_normalize_streaming_send(req WebSocketUpstreamSendRequest) WebSocketUpstreamSendRequest {
	if req.message_type.trim_space() == 'interactive' {
		return req
	}
	mut normalized := req
	mut markdown := feishu_runtime_extract_markdown_text(req.content, req.text, req.content_fields)
	if markdown.trim_space() == '' {
		markdown = '⚙️ **处理中...**'
	}
	normalized.message_type = 'interactive'
	normalized.content = feishu_runtime_interactive_markdown_card(markdown)
	normalized.text = ''
	normalized.content_fields = map[string]string{}
	return normalized
}

fn feishu_runtime_update_http_method(msg_type string) http.Method {
	return feishu.update_http_method(msg_type)
}

fn feishu_runtime_delay_update_card_body(token string, raw_content string) !string {
	return feishu.delay_update_card_body(token, raw_content)
}

fn normalize_feishu_open_base(raw string) string {
	return feishu.normalize_open_base(raw)
}

fn feishu_runtime_root_base(base string) string {
	return feishu.root_base(base)
}

fn feishu_runtime_ws_endpoint_urls(base string) []string {
	return feishu.ws_endpoint_urls(base)
}

fn feishu_runtime_ws_endpoint_body(app_id string, app_secret string) string {
	return feishu.ws_endpoint_body(app_id, app_secret)
}

fn (app &App) feishu_runtime_enabled() bool {
	return app.feishu.enabled || app.provider_instance_list('feishu').len > 0
}

fn (app &App) feishu_runtime_has_dynamic_app(name string) bool {
	return app.provider_instance_get('feishu', name) != none
}

fn (app &App) feishu_runtime_has_static_app(name string) bool {
	if name in app.feishu.static_apps {
		return true
	}
	if app.feishu.static_apps.len == 0 && name in app.feishu.apps
		&& !app.feishu_runtime_has_dynamic_app(name) {
		return true
	}
	return false
}

fn (app &App) feishu_runtime_app_source(name string) string {
	has_static := app.feishu_runtime_has_static_app(name)
	has_dynamic := app.feishu_runtime_has_dynamic_app(name)
	if has_static && has_dynamic {
		return 'mixed'
	}
	if has_dynamic {
		return 'dynamic'
	}
	if has_static {
		return 'static'
	}
	if name in app.feishu.apps {
		return 'runtime'
	}
	return 'unknown'
}

fn (app &App) feishu_runtime_ready() bool {
	return app.feishu_runtime_enabled() && app.feishu_runtime_app_names().len > 0
}

fn (app &App) feishu_runtime_bridge_proxy_only() bool {
	return app.feishu_card_bridge_enabled() && app.feishu_runtime_app_names().len == 0
}

fn (app &App) feishu_runtime_default_app_name() string {
	if 'main' in app.feishu.apps {
		return 'main'
	}
	mut names := []string{}
	for name in app.feishu.apps.keys() {
		names << name
	}
	names.sort()
	return if names.len > 0 { names[0] } else { '' }
}

fn (app &App) feishu_runtime_app_names() []string {
	mut names := []string{}
	for name, cfg in app.feishu.apps {
		if cfg.app_id.trim_space() == '' && cfg.app_secret.trim_space() == '' {
			continue
		}
		names << name
	}
	names.sort()
	return names
}

fn (app &App) feishu_runtime_resolve_app_name(raw string) !string {
	name := raw.trim_space()
	if name != '' {
		if name in app.feishu.apps {
			return name
		}
		return error('unknown feishu app "${name}"')
	}
	default_name := app.feishu_runtime_default_app_name()
	if default_name == '' {
		return error('no configured feishu apps')
	}
	return default_name
}

fn (app &App) feishu_runtime_app_config(name string) !config.FeishuAppConfig {
	resolved := app.feishu_runtime_resolve_app_name(name)!
	if cfg := app.feishu.apps[resolved] {
		return cfg
	}
	return error('missing feishu app config "${resolved}"')
}

fn feishu_runtime_callback_challenge(payload string) string {
	return feishu.callback_challenge(payload)
}

fn (app &App) feishu_runtime_callback_token_valid(app_name string, payload string) bool {
	cfg := app.feishu_runtime_app_config(app_name) or { return false }
	if cfg.verification_token.trim_space() == '' {
		return true
	}
	parsed := json2.decode[json2.Any](payload) or { return false }
	root := parsed.as_map()
	token := feishu_runtime_json_field_string(root, 'token')
	return token != '' && token == cfg.verification_token
}

fn feishu_runtime_pkcs7_unpad(data []u8) ![]u8 {
	return feishu.pkcs7_unpad(data)
}

fn feishu_runtime_callback_signature_valid(headers map[string]string, encrypt_key string, payload string) bool {
	return feishu.callback_signature_valid(headers, encrypt_key, payload)
}

fn feishu_runtime_callback_decrypt_payload(encrypt_key string, payload string) !string {
	return feishu.callback_decrypt_payload(encrypt_key, payload)
}

fn (mut app App) feishu_runtime_ensure(name string) FeishuProviderRuntime {
	app.feishu.mu.@lock()
	defer {
		app.feishu.mu.unlock()
	}
	if runtime := app.feishu.runtime[name] {
		return runtime
	}
	runtime := new_feishu_provider_runtime(name)
	app.feishu.runtime[name] = runtime
	return runtime
}

fn (mut app App) feishu_runtime_update(name string, runtime FeishuProviderRuntime) {
	app.feishu.mu.@lock()
	app.feishu.runtime[name] = runtime
	app.feishu.mu.unlock()
}

fn feishu_runtime_varint_encode(mut out []u8, value u64) {
	feishu.varint_encode(mut out, value)
}

fn feishu_runtime_encode_field_key(mut out []u8, field_number int, wire_type int) {
	feishu.encode_field_key(mut out, field_number, wire_type)
}

fn feishu_runtime_encode_bytes_field(mut out []u8, field_number int, payload []u8) {
	feishu.encode_bytes_field(mut out, field_number, payload)
}

fn feishu_runtime_encode_string_field(mut out []u8, field_number int, payload string) {
	feishu.encode_string_field(mut out, field_number, payload)
}

fn feishu_runtime_proto_header_encode(header FeishuRuntimeProtoHeader) []u8 {
	return feishu.proto_header_encode(header)
}

fn feishu_runtime_proto_frame_encode(frame FeishuRuntimeProtoFrame) []u8 {
	return feishu.proto_frame_encode(frame)
}

fn feishu_runtime_varint_decode(buf []u8, start int) !(u64, int) {
	return feishu.varint_decode(buf, start)
}

fn feishu_runtime_skip_wire(buf []u8, start int, wire_type int) !int {
	return feishu.skip_wire(buf, start, wire_type)
}

fn feishu_runtime_proto_header_decode(buf []u8) !FeishuRuntimeProtoHeader {
	return feishu.proto_header_decode(buf)
}

fn feishu_runtime_proto_frame_decode(buf []u8) !FeishuRuntimeProtoFrame {
	return feishu.proto_frame_decode(buf)
}

fn feishu_runtime_header_map(headers []FeishuRuntimeProtoHeader) map[string]string {
	return feishu.header_map(headers)
}

fn feishu_runtime_event_summary(payload string) executor.FeishuRuntimeEventSummary {
	return feishu.event_summary(payload)
}

fn feishu_runtime_should_dispatch_upstream(summary executor.FeishuRuntimeEventSummary) bool {
	return feishu.should_dispatch_upstream(summary)
}

fn (mut app App) feishu_runtime_snapshot() FeishuRuntimeSnapshot {
	app.feishu.mu.@lock()
	defer {
		app.feishu.mu.unlock()
	}
	mut apps := []FeishuRuntimeAppSnapshot{}
	mut connected_count := 0
	for name in app.feishu_runtime_app_names() {
		runtime := app.feishu.runtime[name] or { new_feishu_provider_runtime(name) }
		if runtime.is_connected() {
			connected_count++
		}
		apps << runtime.app_snapshot_with_source(name, app.feishu_runtime_enabled(),
			app.feishu.open_base_url, app.feishu_runtime_app_source(name),
			app.feishu_runtime_has_static_app(name), app.feishu_runtime_has_dynamic_app(name))
	}
	return FeishuRuntimeSnapshot{
		enabled:         app.feishu_runtime_enabled()
		configured:      app.feishu_runtime_ready()
		app_count:       apps.len
		connected_count: connected_count
		default_app:     app.feishu_runtime_default_app_name()
		apps:            apps
	}
}

fn (mut app App) feishu_runtime_app_snapshot(name string) ?FeishuRuntimeAppSnapshot {
	snapshot := app.feishu_runtime_snapshot()
	for item in snapshot.apps {
		if item.name == name {
			return item
		}
	}
	return none
}

fn (mut app App) feishu_runtime_chats_snapshot(limit int, offset int, instance_filter string, chat_type_filter string, chat_id_filter string) FeishuRuntimeChatsSnapshot {
	app.feishu.mu.@lock()
	defer {
		app.feishu.mu.unlock()
	}
	mut latest_by_chat := map[string]FeishuRuntimeChatSnapshot{}
	for instance, runtime in app.feishu.runtime {
		if instance_filter != '' && instance != instance_filter {
			continue
		}
		for event in runtime.recent_events {
			if event.chat_id.trim_space() == '' {
				continue
			}
			if chat_type_filter != '' && event.chat_type != chat_type_filter {
				continue
			}
			if chat_id_filter != '' && event.chat_id != chat_id_filter {
				continue
			}
			key := '${instance}:${event.chat_id}'
			existing := latest_by_chat[key] or { FeishuRuntimeChatSnapshot{} }
			if existing.chat_id == '' || event.received_at >= existing.last_received_at {
				latest_by_chat[key] = FeishuRuntimeChatSnapshot{
					instance:          instance
					chat_id:           event.chat_id
					chat_type:         event.chat_type
					target_type:       'chat_id'
					target:            event.chat_id
					last_event_type:   event.event_type
					last_message_id:   event.message_id
					last_message_type: event.message_type
					last_sender_id:    event.sender_id
					last_create_time:  event.create_time
					last_received_at:  event.received_at
					seen_count:        existing.seen_count + 1
				}
			} else {
				latest_by_chat[key] = FeishuRuntimeChatSnapshot{
					instance:          existing.instance
					chat_id:           existing.chat_id
					chat_type:         existing.chat_type
					target_type:       existing.target_type
					target:            existing.target
					last_event_type:   existing.last_event_type
					last_message_id:   existing.last_message_id
					last_message_type: existing.last_message_type
					last_sender_id:    existing.last_sender_id
					last_create_time:  existing.last_create_time
					last_received_at:  existing.last_received_at
					seen_count:        existing.seen_count + 1
				}
			}
		}
	}
	mut chats := latest_by_chat.values()
	chats.sort(a.last_received_at > b.last_received_at)
	if offset >= chats.len {
		return FeishuRuntimeChatsSnapshot{
			returned_count: 0
			limit:          limit
			offset:         offset
			instance:       instance_filter
			chat_type:      chat_type_filter
			chat_id:        chat_id_filter
			chats:          []FeishuRuntimeChatSnapshot{}
		}
	}
	end := if offset + limit < chats.len { offset + limit } else { chats.len }
	return FeishuRuntimeChatsSnapshot{
		returned_count: end - offset
		limit:          limit
		offset:         offset
		instance:       instance_filter
		chat_type:      chat_type_filter
		chat_id:        chat_id_filter
		chats:          chats[offset..end].clone()
	}
}

fn (mut app App) feishu_runtime_totals() (i64, i64, i64, i64, i64, i64) {
	app.feishu.mu.@lock()
	defer {
		app.feishu.mu.unlock()
	}
	mut connect_attempts := i64(0)
	mut connect_successes := i64(0)
	mut received_frames := i64(0)
	mut acked_events := i64(0)
	mut messages_sent := i64(0)
	mut send_errors := i64(0)
	for _, runtime in app.feishu.runtime {
		connect_attempts += runtime.connect_attempts
		connect_successes += runtime.connect_successes
		received_frames += runtime.received_frames
		acked_events += runtime.acked_events
		messages_sent += runtime.messages_sent
		send_errors += runtime.send_errors
	}
	return connect_attempts, connect_successes, received_frames, acked_events, messages_sent, send_errors
}

fn (mut app App) feishu_runtime_note_connecting(name string) {
	mut runtime := app.feishu_runtime_ensure(name)
	runtime.note_connecting()
	app.feishu_runtime_update(name, runtime)
}

fn (mut app App) feishu_runtime_note_connected(name string, ws_url string) {
	mut runtime := app.feishu_runtime_ensure(name)
	runtime.note_connected(ws_url)
	app.feishu_runtime_update(name, runtime)
}

fn (mut app App) feishu_runtime_note_disconnected(name string, reason string) {
	log.error('[feishu] ❌ disconnected: name=${name} reason=${reason}')
	mut runtime := app.feishu_runtime_ensure(name)
	runtime.note_disconnected(reason)
	app.feishu_runtime_update(name, runtime)
}

fn (mut app App) feishu_runtime_note_frame(name string) {
	mut runtime := app.feishu_runtime_ensure(name)
	runtime.note_frame()
	app.feishu_runtime_update(name, runtime)
}

fn (mut app App) feishu_runtime_note_ack(name string) {
	mut runtime := app.feishu_runtime_ensure(name)
	runtime.note_ack()
	app.feishu_runtime_update(name, runtime)
}

fn (mut app App) feishu_runtime_note_send(name string, ok bool) {
	mut runtime := app.feishu_runtime_ensure(name)
	runtime.note_send(ok)
	app.feishu_runtime_update(name, runtime)
}

fn (mut app App) feishu_runtime_push_event(name string, snapshot FeishuRuntimeEventSnapshot) {
	mut runtime := app.feishu_runtime_ensure(name)
	runtime.push_event(snapshot, app.feishu.recent_event_limit)
	app.feishu_runtime_update(name, runtime)
}

fn feishu_runtime_clone_headers_with_type(frame FeishuRuntimeProtoFrame, next_type string) []FeishuRuntimeProtoHeader {
	return feishu.clone_headers_with_type(frame, next_type)
}

fn feishu_runtime_build_pong(frame FeishuRuntimeProtoFrame) FeishuRuntimeProtoFrame {
	return feishu.build_pong(frame)
}

fn feishu_runtime_build_ack(frame FeishuRuntimeProtoFrame, status int, headers map[string]string, data string) FeishuRuntimeProtoFrame {
	return feishu.build_ack(frame, status, headers, data)
}

fn headers_to_type(headers []FeishuRuntimeProtoHeader) string {
	return feishu.headers_to_type(headers)
}

fn feishu_runtime_ws_url_service_id(ws_url string) i32 {
	return feishu.ws_url_service_id(ws_url)
}

fn feishu_runtime_build_client_ping(service_id i32) FeishuRuntimeProtoFrame {
	return feishu.build_client_ping(service_id)
}

fn (mut app App) feishu_runtime_ping_interval_seconds(instance string) int {
	app.feishu.mu.@lock()
	defer {
		app.feishu.mu.unlock()
	}
	if runtime := app.feishu.runtime[instance] {
		return runtime.ping_interval_seconds_value()
	}
	return 5
}

fn (mut app App) feishu_runtime_note_client_config(instance string, cfg FeishuRuntimeClientConfig) {
	mut runtime := app.feishu_runtime_ensure(instance)
	runtime.note_client_config(cfg)
	app.feishu_runtime_update(instance, runtime)
}

fn feishu_runtime_ping_loop(mut app App, instance string, ws_url string, mut ws websocket.Client) {
	service_id := feishu_runtime_ws_url_service_id(ws_url)
	if service_id <= 0 {
		return
	}
	mut interval_seconds := app.feishu_runtime_ping_interval_seconds(instance)
	if interval_seconds <= 0 {
		interval_seconds = 5
	}
	for ws.get_state() == .open {
		ping := feishu_runtime_build_client_ping(service_id)
		ws.write(feishu_runtime_proto_frame_encode(ping), .binary_frame) or {
			log.error('[feishu] ❌ ping send failed: ${err}')
			return
		}
		log.info('[feishu] 💓 heartbeat sent')
		if ws.get_state() != .open {
			return
		}
		time.sleep(interval_seconds * time.second)
	}
}

fn (mut app App) feishu_provider_pull_ws_endpoint(app_name string) !string {
	app_cfg := app.feishu_runtime_app_config(app_name)!
	body := feishu_runtime_ws_endpoint_body(app_cfg.app_id, app_cfg.app_secret)
	mut last_status := 0
	mut last_error := ''
	for endpoint_url in feishu_runtime_ws_endpoint_urls(app.feishu.open_base_url) {
		resp := app.feishu_runtime_control_http_fetch(
			url:    endpoint_url
			method: .post
			data:   body
			header: http.new_header(key: .content_type, value: 'application/json; charset=utf-8')
		) or {
			last_error = err.msg()
			continue
		}
		last_status = resp.status_code
		if resp.status_code == 404 {
			last_error = 'status 404 at ${endpoint_url}'
			continue
		}
		if resp.status_code != 200 {
			return error('feishu ws endpoint request failed with status ${resp.status_code}')
		}
		decoded := json.decode(FeishuRuntimeWsEndpointResponse, resp.body)!
		if decoded.code != 0 || decoded.data.url.trim_space() == '' {
			detail := if decoded.msg.trim_space() != '' {
				decoded.msg
			} else {
				resp.body.trim_space()
			}
			return error('feishu ws endpoint error: code=${decoded.code} detail=${detail}')
		}
		app.feishu_runtime_note_client_config(app_name, decoded.data.client_config)
		return decoded.data.url
	}
	if last_status > 0 {
		return error('feishu ws endpoint request failed with status ${last_status}')
	}
	return error('feishu ws endpoint request failed: ${last_error}')
}

fn (mut app App) feishu_runtime_tenant_access_token(app_name string) !string {
	_ := app.feishu_runtime_app_config(app_name)!
	now := time.now().unix()
	app.feishu.mu.@lock()
	if runtime := app.feishu.runtime[app_name] {
		if runtime.tenant_access_token != ''
			&& now + i64(app.feishu.token_refresh_skew_seconds) < runtime.tenant_access_token_expire_unix {
			token := runtime.tenant_access_token
			app.feishu.mu.unlock()
			return token
		}
	}
	app.feishu.mu.unlock()
	app_cfg := app.feishu_runtime_app_config(app_name)!
	body := json.encode({
		'app_id':     app_cfg.app_id
		'app_secret': app_cfg.app_secret
	})
	resp := app.feishu_runtime_http_fetch(
		url:    '${app.feishu.open_base_url}/auth/v3/tenant_access_token/internal'
		method: .post
		data:   body
		header: http.new_header(key: .content_type, value: 'application/json; charset=utf-8')
	)!
	if resp.status_code != 200 {
		return error('feishu tenant token request failed with status ${resp.status_code}')
	}
	decoded := json.decode(FeishuRuntimeTenantTokenResponse, resp.body)!
	if decoded.code != 0 || decoded.tenant_access_token.trim_space() == '' {
		return error('feishu tenant token error: ${decoded.msg}')
	}
	mut runtime := app.feishu_runtime_ensure(app_name)
	runtime.cache_tenant_access_token(decoded.tenant_access_token, now + i64(decoded.expire))
	app.feishu_runtime_update(app_name, runtime)
	return decoded.tenant_access_token
}

fn (mut app App) feishu_runtime_send_message(req FeishuRuntimeSendMessageRequest) !FeishuRuntimeSendMessageResult {
	app_name := app.feishu_runtime_resolve_app_name(req.app)!
	if !app.feishu_runtime_ready() {
		return error('feishu gateway is not configured')
	}
	receive_id_type := if req.receive_id_type.trim_space() == '' {
		'chat_id'
	} else {
		req.receive_id_type.trim_space()
	}
	if req.receive_id.trim_space() == '' {
		return error('missing receive_id')
	}
	msg_type := if req.msg_type.trim_space() == '' { 'text' } else { req.msg_type.trim_space() }
	content := feishu_runtime_build_message_content(msg_type, req.content, req.text,
		req.content_fields)!
	token := app.feishu_runtime_tenant_access_token(app_name)!
	mut header := http.new_header(key: .content_type, value: 'application/json; charset=utf-8')
	header.add_custom('authorization', 'Bearer ${token}') or {} // safe to ignore: header append on detached request
	mut payload := ''
	mut url := ''
	if receive_id_type == 'message_id' {
		payload = json.encode({
			'msg_type': msg_type
			'content':  content
			'uuid':     req.uuid
		})
		url = '${app.feishu.open_base_url}/im/v1/messages/${req.receive_id.trim_space()}/reply'
	} else {
		payload = json.encode({
			'receive_id': req.receive_id
			'msg_type':   msg_type
			'content':    content
			'uuid':       req.uuid
		})
		url = '${app.feishu.open_base_url}/im/v1/messages?receive_id_type=${receive_id_type}'
	}
	log.info('[feishu] 📤 sending message: method=POST url=${url} payload=${payload.len} bytes')
	resp := app.feishu_runtime_http_fetch(
		url:    url
		method: .post
		data:   payload
		header: header
	) or {
		app.feishu_runtime_note_send(app_name, false)
		log.error('[feishu] ❌ send fetch failed: ${err}')
		return err
	}
	log.info('[feishu] 📩 send response: status=${resp.status_code} body=${resp.body}')
	if resp.status_code != 200 {
		app.feishu_runtime_note_send(app_name, false)
		return error('feishu message send failed with status ${resp.status_code}: ${resp.body}')
	}
	decoded := json.decode(FeishuRuntimeSendMessageResponse, resp.body) or {
		app.feishu_runtime_note_send(app_name, false)
		return error('invalid feishu send response: ${err}')
	}
	if decoded.code != 0 {
		app.feishu_runtime_note_send(app_name, false)
		return error('feishu send error: ${decoded.msg}')
	}
	app.feishu_runtime_note_send(app_name, true)
	return FeishuRuntimeSendMessageResult{
		ok:         true
		message_id: decoded.data.message_id
	}
}

fn (mut app App) feishu_runtime_upload_image(req FeishuRuntimeUploadImageRequest) !FeishuRuntimeUploadImageResult {
	if req.content_length > feishu_runtime_max_upload_image_bytes {
		return error('image_too_large')
	}
	data := base64.decode_str(req.data_base64)
	if data == '' {
		return error('invalid_image_data')
	}
	return app.feishu_runtime_upload_image_bytes(req, data.bytes())
}

fn (mut app App) feishu_runtime_upload_image_bytes(req FeishuRuntimeUploadImageRequest, data []u8) !FeishuRuntimeUploadImageResult {
	app_name := app.feishu_runtime_resolve_app_name(req.app)!
	if data.len == 0 {
		return error('missing_image_data')
	}
	if data.len > feishu_runtime_max_upload_image_bytes {
		return error('image_too_large')
	}
	token := app.feishu_runtime_tenant_access_token(app_name)!
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
	mut header := http.new_header()
	header.set(.authorization, 'Bearer ${token}')
	resp := app.feishu_runtime_http_post_multipart_form('${app.feishu.open_base_url}/im/v1/images', http.PostMultipartFormConfig{
		form:   {
			'image_type': image_type
		}
		files:  {
			'image': [
				http.FileData{
					filename:     filename
					content_type: content_type
					data:         data.bytestr()
				},
			]
		}
		header: header
	}) or { return error('feishu image upload request failed: ${err.msg()}') }
	if resp.status_code < 200 || resp.status_code >= 300 {
		return error('feishu image upload failed with status ${resp.status_code}')
	}
	decoded := json.decode(FeishuRuntimeUploadImageResponse, resp.body) or {
		return error('invalid_feishu_image_upload_response')
	}
	if decoded.code != 0 || decoded.data.image_key.trim_space() == '' {
		return error('feishu image upload error: code=${decoded.code} detail=${resp.body}')
	}
	return FeishuRuntimeUploadImageResult{
		ok:        true
		image_key: decoded.data.image_key
	}
}

fn (mut app App) feishu_runtime_update_message(req FeishuRuntimeUpdateMessageRequest) !FeishuRuntimeSendMessageResult {
	app_name := app.feishu_runtime_resolve_app_name(req.app)!
	if !app.feishu_runtime_ready() {
		return error('feishu gateway is not configured')
	}
	message_id_type := if req.message_id_type.trim_space() == '' {
		'message_id'
	} else {
		req.message_id_type.trim_space()
	}
	msg_type := if req.msg_type.trim_space() == '' { 'text' } else { req.msg_type.trim_space() }
	target := req.message_id.trim_space()
	mut content_raw := req.content

	if message_id_type == 'token' && msg_type != 'interactive' {
		return error('token-based feishu delayed update only supports interactive cards')
	}
	if message_id_type == 'message_id' {
		if target == '' {
			return error('missing message_id')
		}
		if msg_type != 'interactive' {
			return error('message_id-based feishu update only supports interactive cards')
		}
	}

	// Support buffer placeholder replacement or auto-append
	if target != '' {
		app.feishu.mu.@lock()
		if buf := app.feishu.buffers[target] {
			if content_raw.contains('{{content}}') {
				escaped := buf.content.replace('\\', '\\\\').replace('"', '\\"').replace('\n',
					'\\n')
				content_raw = content_raw.replace('{{content}}', escaped)
				log.info('[feishu] 🧩 replaced {{content}} placeholder')
			}
		}
		app.feishu.mu.unlock()
	}

	token := app.feishu_runtime_tenant_access_token(app_name)!
	mut header := http.new_header(key: .content_type, value: 'application/json; charset=utf-8')
	header.add_custom('authorization', 'Bearer ${token}') or {} // safe to ignore: header append on detached request
	mut payload := ''
	mut url := ''
	mut method := http.Method.post
	if message_id_type == 'token' {
		payload = feishu_runtime_delay_update_card_body(target, content_raw)!
		url = '${app.feishu.open_base_url}/interactive/v1/card/update'
		method = .post
	} else if message_id_type == 'message_id' {
		content := feishu_runtime_build_message_content(msg_type, content_raw, req.text,
			req.content_fields)!
		payload = json.encode({
			'msg_type': msg_type
			'content':  content
			'uuid':     req.uuid
		})
		url = '${app.feishu.open_base_url}/im/v1/messages/${target}'
		method = feishu_runtime_update_http_method(msg_type)
	} else {
		return error('unsupported feishu update target type ${message_id_type}')
	}
	log.info('[feishu] 📤 sending update: method=${method} url=${url} payload=${payload.len} bytes')
	resp := app.feishu_runtime_http_fetch(url: url, method: method, data: payload, header: header) or {
		app.feishu_runtime_note_send(app_name, false)
		log.error('[feishu] ❌ update fetch failed: ${err}')
		return err
	}
	log.info('[feishu] 📩 update response: status=${resp.status_code} body=${resp.body}')
	if resp.status_code != 200 {
		app.feishu_runtime_note_send(app_name, false)
		return error('feishu message update failed with status ${resp.status_code}: ${resp.body}')
	}
	decoded := json.decode(FeishuRuntimeSendMessageResponse, resp.body) or {
		app.feishu_runtime_note_send(app_name, false)
		return error('invalid feishu update response: ${err}')
	}
	if decoded.code != 0 {
		app.feishu_runtime_note_send(app_name, false)
		return error('feishu update error: ${decoded.msg}')
	}
	app.feishu_runtime_note_send(app_name, true)
	return FeishuRuntimeSendMessageResult{
		ok:         true
		message_id: if decoded.data.message_id.trim_space() != '' {
			decoded.data.message_id
		} else {
			target
		}
	}
}

// ── Stream Buffering ───────────────────────────────────────────────────

fn (mut app App) feishu_runtime_buffer_patch(req WebSocketUpstreamSendRequest) {
	mut current_target := req.target
	if current_target == '' {
		return
	}

	for {
		app.feishu.mu.@lock()
		if current_target !in app.feishu.buffers {
			app.feishu.buffers[current_target] = FeishuStreamBuffer{
				message_id:    current_target
				app:           req.instance
				last_flush:    time.now().unix_milli()
				segment_index: 1
			}
		}
		mut buf := app.feishu.buffers[current_target]
		if !buf.sealed {
			buf.content += req.text
			buf.last_delta = time.now().unix_milli()
			app.feishu.buffers[current_target] = buf
			app.feishu.mu.unlock()
			return
		}
		if buf.next_message_id != '' {
			next_target := buf.next_message_id
			app.feishu.mu.unlock()
			current_target = next_target
			continue
		}
		app_name := buf.app
		stream_id := buf.stream_id
		receive_id := buf.receive_id
		receive_id_type := buf.receive_id_type
		segment_index := if buf.segment_index > 0 { buf.segment_index + 1 } else { 2 }
		app.feishu.mu.unlock()

		if receive_id.trim_space() == '' || receive_id_type.trim_space() == '' {
			return
		}

		card_payload := feishu_runtime_streaming_card(req.text, segment_index)
		send_result := app.feishu_runtime_send_message(FeishuRuntimeSendMessageRequest{
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
		app.feishu.mu.@lock()
		if mut sealed_buf := app.feishu.buffers[current_target] {
			if sealed_buf.next_message_id == '' {
				sealed_buf.next_message_id = send_result.message_id
				app.feishu.buffers[current_target] = sealed_buf
			}
		}
		app.feishu.buffers[send_result.message_id] = FeishuStreamBuffer{
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
		app.feishu.mu.unlock()
		if stream_id != '' {
			app.codex_add_stream_target(app.codex_resolve_instance_for_stream(stream_id),
				stream_id, CodexTarget{
				platform:   'feishu'
				message_id: send_result.message_id
			})
			app.dispatch_feishu_message_sent(stream_id, send_result.message_id)
		}
		return
	}
}

fn (mut app App) feishu_runtime_register_stream_buffer(message_id string, stream_id string, app_name string, receive_id string, receive_id_type string, initial_content string) {
	if message_id == '' {
		return
	}
	now := time.now().unix_milli()
	app.feishu.mu.@lock()
	defer {
		app.feishu.mu.unlock()
	}
	mut buf := app.feishu.buffers[message_id] or {
		FeishuStreamBuffer{
			message_id: message_id
			app:        app_name
			last_flush: now
		}
	}
	if app_name != '' {
		buf.app = app_name
	}
	if stream_id != '' {
		buf.stream_id = stream_id
	}
	if receive_id != '' {
		buf.receive_id = receive_id
	}
	if receive_id_type != '' {
		buf.receive_id_type = receive_id_type
	}
	if buf.segment_index <= 0 {
		buf.segment_index = 1
	}
	if initial_content != '' {
		buf.content = initial_content
		buf.rendered_content = initial_content
		buf.last_delta = now
		buf.last_flush = now
	}
	app.feishu.buffers[message_id] = buf
}

fn feishu_runtime_split_content_runes(content string, limit int) (string, string) {
	return feishu.split_content_runes(content, limit)
}

fn feishu_runtime_streaming_preview_markdown(content string) string {
	return feishu.streaming_preview_markdown(content)
}

fn feishu_runtime_render_final_card(markdown string, template_content string) string {
	return feishu.render_final_card(markdown, template_content)
}

fn (mut app App) feishu_runtime_send_followup_segment(buf FeishuStreamBuffer, markdown string, finish bool,
	template_content string) !string {
	if buf.receive_id.trim_space() == '' || buf.receive_id_type.trim_space() == '' {
		return error('stream followup segment missing send context')
	}
	card_payload := if finish {
		feishu_runtime_render_final_card(markdown, template_content)
	} else {
		feishu_runtime_streaming_card(markdown, buf.segment_index)
	}
	send_result := app.feishu_runtime_send_message(FeishuRuntimeSendMessageRequest{
		app:             buf.app
		receive_id_type: buf.receive_id_type
		receive_id:      buf.receive_id
		msg_type:        'interactive'
		content:         card_payload
	})!
	if buf.stream_id.trim_space() != '' {
		app.codex_add_stream_target(app.codex_resolve_instance_for_stream(buf.stream_id),
			buf.stream_id, CodexTarget{
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
	mut to_flush := []FeishuStreamBuffer{}

	app.feishu.mu.@lock()
	for _, buf in app.feishu.buffers {
		if buf.last_delta >= buf.last_flush && now - buf.last_flush >= 400
			&& buf.content.trim_space() != '' {
			to_flush << buf
		}
	}
	app.feishu.mu.unlock()

	for buf in to_flush {
		preview_markdown := feishu_runtime_streaming_preview_markdown(buf.content)
		if preview_markdown == '' {
			continue
		}
		if preview_markdown == buf.rendered_content {
			app.feishu.mu.@lock()
			if mut active := app.feishu.buffers[buf.message_id] {
				active.last_flush = time.now().unix_milli()
				app.feishu.buffers[buf.message_id] = active
			}
			app.feishu.mu.unlock()
			continue
		}
		card_payload := feishu_runtime_streaming_card(preview_markdown, 1)
		app.feishu_runtime_update_message(FeishuRuntimeUpdateMessageRequest{
			app:        buf.app
			message_id: buf.message_id
			msg_type:   'interactive'
			content:    card_payload
		}) or {
			log.error('[feishu] ❌ preview flush failed for ${buf.message_id}: ${err}')
			continue
		}
		app.feishu.mu.@lock()
		if mut active := app.feishu.buffers[buf.message_id] {
			active.last_flush = time.now().unix_milli()
			active.rendered_content = preview_markdown
			app.feishu.buffers[buf.message_id] = active
		}
		app.feishu.mu.unlock()
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
	app.feishu.mu.@lock()
	buf := app.feishu.buffers[message_id] or {
		app.feishu.mu.unlock()
		if finish {
			log.info('[feishu] 🚿 explicit flush without buffer for msg_id=${message_id} (finish=true, fallback=no-op)')
			return
		}
		return error('no buffer found for message_id: ${message_id}')
	}
	app.feishu.mu.unlock()

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
		head, mut tail := feishu_runtime_split_content_runes(content,
			feishu_stream_buffer_rollover_runes)
		final_head := if tail == '' {
			feishu_runtime_render_final_card(head, content_raw)
		} else {
			feishu_runtime_interactive_markdown_card(head)
		}
		app.feishu_runtime_update_message(FeishuRuntimeUpdateMessageRequest{
			app:        buf.app
			message_id: buf.message_id
			msg_type:   'interactive'
			content:    final_head
		})!
		mut segment := 2
		mut last_message_id := buf.message_id
		for tail != '' {
			head_chunk, next_tail := feishu_runtime_split_content_runes(tail,
				feishu_stream_buffer_rollover_runes)
			is_last := next_tail == ''
			mut followup_buf := buf
			followup_buf.segment_index = segment
			last_message_id = app.feishu_runtime_send_followup_segment(followup_buf, head_chunk,
				is_last, content_raw)!
			tail = next_tail
			segment++
		}
		app.feishu.mu.@lock()
		if mut active := app.feishu.buffers[buf.message_id] {
			active.content = ''
			active.rendered_content = content
			active.last_flush = time.now().unix_milli()
			active.last_delta = active.last_flush
			active.sealed = true
			active.next_message_id = ''
			active.segment_index = if last_message_id == buf.message_id { 1 } else { segment }
			app.feishu.buffers[buf.message_id] = active
		}
		if last_message_id != buf.message_id {
			app.feishu.buffers.delete(last_message_id)
		}
		app.feishu.mu.unlock()
		return
	}

	if buf.content.trim_space() == '' {
		return
	}
	preview_markdown := feishu_runtime_streaming_preview_markdown(buf.content)
	if preview_markdown == '' {
		return
	}
	app.feishu_runtime_update_message(FeishuRuntimeUpdateMessageRequest{
		app:        buf.app
		message_id: buf.message_id
		msg_type:   'interactive'
		content:    feishu_runtime_streaming_card(preview_markdown, 1)
	})!
	app.feishu.mu.@lock()
	if mut active := app.feishu.buffers[buf.message_id] {
		active.last_flush = time.now().unix_milli()
		active.rendered_content = preview_markdown
		app.feishu.buffers[buf.message_id] = active
	}
	app.feishu.mu.unlock()
}

fn (mut app App) feishu_runtime_clear_buffer(message_id string) {
	app.feishu.mu.@lock()
	app.feishu.buffers.delete(message_id)
	app.feishu.mu.unlock()
}

fn (mut app App) feishu_runtime_stream_id_for_buffer(message_id string) string {
	if message_id == '' {
		return ''
	}
	app.feishu.mu.@lock()
	defer {
		app.feishu.mu.unlock()
	}
	if buf := app.feishu.buffers[message_id] {
		return buf.stream_id
	}
	return ''
}

fn (mut app App) feishu_runtime_clear_buffer_chain(message_id string) int {
	if message_id == '' {
		return 0
	}
	mut cleared := 0
	mut current := message_id
	for current != '' {
		mut next := ''
		app.feishu.mu.@lock()
		if buf := app.feishu.buffers[current] {
			next = buf.next_message_id
			app.feishu.buffers.delete(current)
			cleared++
		}
		app.feishu.mu.unlock()
		current = next
	}
	return cleared
}

fn (mut app App) feishu_runtime_clear_stream_buffers(stream_id string) int {
	if stream_id == '' {
		return 0
	}
	app.feishu.mu.@lock()
	keys := app.feishu.buffers.keys()
	app.feishu.mu.unlock()
	mut cleared := 0
	for key in keys {
		app.feishu.mu.@lock()
		buf := app.feishu.buffers[key] or {
			app.feishu.mu.unlock()
			continue
		}
		app.feishu.mu.unlock()
		if buf.stream_id == stream_id {
			cleared += app.feishu_runtime_clear_buffer_chain(key)
		}
	}
	return cleared
}

fn (mut app App) feishu_provider_handle_binary_message(instance string, mut ws websocket.Client, msg &websocket.Message) ! {
	if msg.opcode != .binary_frame {
		return
	}
	app_name := app.feishu_runtime_resolve_app_name(instance)!
	frame := feishu_runtime_proto_frame_decode(msg.payload) or {
		log.error('[feishu] ❌ proto decode failed: ${err}')
		return err
	}
	app.feishu_runtime_note_frame(app_name)
	headers := feishu_runtime_header_map(frame.headers)
	msg_type := headers[feishu_runtime_header_type] or { '' }
	trace_id := headers[feishu_runtime_header_trace] or { '' }
	seq_id := headers[feishu_runtime_header_seq] or { '${frame.seq_id}' }
	if frame.method == 2 || msg_type == feishu_runtime_message_ping {
		pong := feishu_runtime_build_pong(frame)
		ws.write(feishu_runtime_proto_frame_encode(pong), .binary_frame)!
		return
	}
	if frame.method == 3 || msg_type == feishu_runtime_message_pong {
		log.info('[feishu] 💓 heartbeat pong received')
		if frame.payload.len > 0 {
			cfg := json.decode(FeishuRuntimeClientConfig, frame.payload.bytestr()) or {
				FeishuRuntimeClientConfig{}
			}
			app.feishu_runtime_note_client_config(app_name, cfg)
		}
		return
	}
	if msg_type !in [feishu_runtime_message_data, feishu_runtime_message_event,
		feishu_runtime_message_card] {
		return
	}
	payload := frame.payload.bytestr()
	summary := feishu_runtime_event_summary(payload)
	app.feishu_runtime_push_event(app_name, FeishuRuntimeEventSnapshot{
		seq_id:            seq_id
		trace_id:          trace_id
		action:            ''
		event_id:          summary.event_id
		event_kind:        summary.event_kind
		event_type:        summary.event_type
		message_id:        summary.message_id
		message_type:      summary.message_type
		chat_id:           summary.chat_id
		chat_type:         summary.chat_type
		target_type:       summary.target_type
		target:            summary.target
		open_message_id:   summary.open_message_id
		root_id:           summary.root_id
		parent_id:         summary.parent_id
		create_time:       summary.create_time
		sender_id:         summary.sender_id
		sender_id_type:    summary.sender_id_type
		sender_tenant_key: summary.sender_tenant_key
		action_tag:        summary.action_tag
		action_value:      summary.action_value
		token:             summary.token
		received_at:       time.now().unix()
		payload:           payload
	})
	log.info('[feishu] 📩 event received: trace_id=${trace_id} type=${summary.event_type} kind=${summary.event_kind} chat_id=${summary.chat_id} msg_id=${summary.message_id} event_id=${summary.event_id}')
	log.info('[feishu][debug] ws.payload.${summary.event_type}: ${payload}')
	app.emit('feishu.event', {
		'app':               app_name
		'seq_id':            seq_id
		'trace_id':          trace_id
		'event_id':          summary.event_id
		'event_kind':        summary.event_kind
		'event_type':        summary.event_type
		'message_id':        summary.message_id
		'message_type':      summary.message_type
		'chat_id':           summary.chat_id
		'chat_type':         summary.chat_type
		'target_type':       summary.target_type
		'target':            summary.target
		'open_message_id':   summary.open_message_id
		'root_id':           summary.root_id
		'parent_id':         summary.parent_id
		'create_time':       summary.create_time
		'sender_id':         summary.sender_id
		'sender_id_type':    summary.sender_id_type
		'sender_tenant_key': summary.sender_tenant_key
		'action_tag':        summary.action_tag
		'action_value':      summary.action_value
		'token':             summary.token
	})
	mut ack_status := 200
	mut ack_headers := map[string]string{}
	mut ack_data := ''
	mut bridged := false
	if app.feishu.card_bridge_target_id.trim_space() != ''
		&& feishu_runtime_should_dispatch_upstream(summary) {
		log.info('[feishu] 🔁 bridging upstream event to local runtime target=${app.feishu.card_bridge_target_id} trace_id=${trace_id} event_type=${summary.event_type} message_id=${summary.message_id}')
		bridge_resp := app.feishu_card_bridge_dispatch_callback(app_name, trace_id, summary,
			payload) or {
			log.error('[feishu] ❌ bridge upstream dispatch failed: trace_id=${trace_id} event_type=${summary.event_type} message_id=${summary.message_id} ${err}')
			executor.FeishuCardBridgeResult{
				error: err.msg()
			}
		}
		if bridge_resp.error == '' {
			bridged = true
			if summary.event_type == 'card.action.trigger' {
				ack_status = if bridge_resp.status > 0 { bridge_resp.status } else { 200 }
				ack_headers = bridge_resp.headers.clone()
				ack_data = bridge_resp.body
			}
		}
	}
	if !bridged && app.has_websocket_upstream_logic_executor()
		&& feishu_runtime_should_dispatch_upstream(summary) {
		log.info('[feishu] 📤 dispatching upstream event to logic executor kind=${app.logic_executor_kind()}')
		mut activity_snapshot := WebSocketUpstreamActivitySnapshot{
			provider:    websocket_upstream_provider_feishu
			instance:    app_name
			trace_id:    trace_id
			activity_id: seq_id
			event_type:  summary.event_type
			message_id:  summary.message_id
			target_type: summary.target_type
			target:      summary.target
			payload:     payload
			received_at: time.now().unix()
			recorded_at: time.now().unix()
		}
		outcome := app.kernel_dispatch_websocket_upstream_handled(app.kernel_websocket_upstream_dispatch_request_with_event(summary.event_kind,
			seq_id, websocket_upstream_provider_feishu, app_name, trace_id, summary.event_type,
			summary.message_id, summary.target, summary.target_type, payload, time.now().unix(), {
			'event_id':          summary.event_id
			'chat_type':         summary.chat_type
			'message_type':      summary.message_type
			'open_message_id':   summary.open_message_id
			'root_id':           summary.root_id
			'parent_id':         summary.parent_id
			'create_time':       summary.create_time
			'sender_id':         summary.sender_id
			'sender_id_type':    summary.sender_id_type
			'sender_tenant_key': summary.sender_tenant_key
			'action_tag':        summary.action_tag
			'action_value':      summary.action_value
			'token':             summary.token
		})) or {
			log.error('[feishu] ❌ dispatch error: ${err}')
			app.emit('websocket_upstream.dispatch.error', {
				'provider': websocket_upstream_provider_feishu
				'instance': app_name
				'trace_id': trace_id
				'error':    err.msg()
			})
			activity_snapshot.worker_error = err.msg()
			activity_snapshot.error_class = 'transport_error'
			app.websocket_upstream_record_activity(activity_snapshot)
			return
		}
		resp := outcome.response
		if resp.error != '' {
			app.emit('websocket_upstream.dispatch.error', {
				'provider':    websocket_upstream_provider_feishu
				'instance':    app_name
				'trace_id':    trace_id
				'error':       resp.error
				'error_class': resp.error_class
			})
			activity_snapshot.worker_error = resp.error
			activity_snapshot.error_class = resp.error_class
			app.websocket_upstream_record_activity(activity_snapshot)
			return
		}
		activity_snapshot.worker_handled = resp.handled
		if summary.event_type == 'card.action.trigger' {
			ack_status = if resp.status > 0 { resp.status } else { 200 }
			ack_headers = resp.headers.clone()
			ack_data = resp.body
		}
		log.info('[feishu] ✅ logic executor returned: handled=${resp.handled} commands=${resp.commands.len} error=${resp.error}')
		activity_snapshot.commands = outcome.command_snapshots
		activity_snapshot.command_error = outcome.command_error
		app.websocket_upstream_record_activity(activity_snapshot)
		if outcome.command_error != '' {
			app.emit('websocket_upstream.command.error', {
				'provider': websocket_upstream_provider_feishu
				'instance': app_name
				'trace_id': trace_id
				'error':    outcome.command_error
			})
		}
	}
	ack := feishu_runtime_build_ack(frame, ack_status, ack_headers, ack_data)
	ws.write(feishu_runtime_proto_frame_encode(ack), .binary_frame)!
	app.feishu_runtime_note_ack(app_name)
}

@['/admin/runtime/feishu'; get]
pub fn (mut app App) admin_runtime_feishu(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime/feishu' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	body := app.provider_runtime_snapshot('feishu') or { '{}' }
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/feishu'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}

@['/admin/runtime/feishu/chats'; get]
pub fn (mut app App) admin_runtime_feishu_chats(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime/feishu/chats' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
	instance_filter := (ctx.query['instance'] or { '' }).trim_space()
	chat_type_filter := (ctx.query['chat_type'] or { '' }).trim_space()
	chat_id_filter := (ctx.query['chat_id'] or { '' }).trim_space()
	body := json.encode(app.feishu_runtime_chats_snapshot(limit, offset, instance_filter,
		chat_type_filter, chat_id_filter))
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/feishu/chats'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}

@['/callbacks/feishu'; post]
pub fn (mut app App) feishu_callback_default(mut ctx Context) veb.Result {
	return app.feishu_callback_by_app(mut ctx, '')
}

@['/callbacks/feishu/:app'; post]
pub fn (mut app App) feishu_callback(mut ctx Context, app_name string) veb.Result {
	return app.feishu_callback_by_app(mut ctx, app_name)
}

fn (mut app App) feishu_callback_by_app(mut ctx Context, raw_app string) veb.Result {
	path := if ctx.req.url == '' {
		if raw_app.trim_space() == '' { '/callbacks/feishu' } else { '/callbacks/feishu/${raw_app}' }
	} else {
		ctx.req.url
	}
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	app_name := app.feishu_runtime_resolve_app_name(raw_app) or {
		ctx.res.set_status(http.status_from_int(404))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'unknown_feishu_app'
		}))
	}
	app_cfg := app.feishu_runtime_app_config(app_name) or {
		ctx.res.set_status(http.status_from_int(404))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'unknown_feishu_app'
		}))
	}
	headers := header_map_from_request(ctx.req)
	raw_payload := ctx.req.data
	if !feishu_runtime_callback_signature_valid(headers, app_cfg.encrypt_key, raw_payload) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'invalid_feishu_callback_signature'
		}))
	}
	payload := feishu_runtime_callback_decrypt_payload(app_cfg.encrypt_key, raw_payload) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'invalid_feishu_callback_encryption'
		}))
	}
	challenge := feishu_runtime_callback_challenge(payload)
	if challenge != '' {
		if !app.feishu_runtime_callback_token_valid(app_name, payload) {
			ctx.res.set_status(http.status_from_int(403))
			return ctx.text(json.encode(AdminErrorResponse{
				error: 'invalid_feishu_callback_token'
			}))
		}
		app.emit('http.request', {
			'method':     'POST'
			'path':       '/callbacks/feishu'
			'status':     '200'
			'request_id': req_id
			'trace_id':   trace_id
			'provider':   'feishu'
			'instance':   app_name
			'callback':   'challenge'
		})
		return ctx.text(json.encode(FeishuCallbackChallengeResponse{
			challenge: challenge
		}))
	}
	if !app.feishu_runtime_callback_token_valid(app_name, payload) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'invalid_feishu_callback_token'
		}))
	}
	summary := feishu_runtime_event_summary(payload)
	app.feishu_runtime_push_event(app_name, FeishuRuntimeEventSnapshot{
		seq_id:            'callback-${time.now().unix_micro()}'
		trace_id:          trace_id
		action:            'callback'
		event_id:          summary.event_id
		event_kind:        summary.event_kind
		event_type:        summary.event_type
		message_id:        summary.message_id
		message_type:      summary.message_type
		chat_id:           summary.chat_id
		chat_type:         summary.chat_type
		target_type:       summary.target_type
		target:            summary.target
		open_message_id:   summary.open_message_id
		root_id:           summary.root_id
		parent_id:         summary.parent_id
		create_time:       summary.create_time
		sender_id:         summary.sender_id
		sender_id_type:    summary.sender_id_type
		sender_tenant_key: summary.sender_tenant_key
		action_tag:        summary.action_tag
		action_value:      summary.action_value
		token:             summary.token
		received_at:       time.now().unix()
		payload:           payload
	})
	log.info('[feishu] 📩 callback received: type=${summary.event_type} kind=${summary.event_kind} chat_id=${summary.chat_id} msg_id=${summary.message_id}')
	log.info('[feishu][debug] callback.payload.${summary.event_type}: ${payload}')
	if summary.event_type == 'card.action.trigger'
		&& app.feishu.card_bridge_target_id.trim_space() != '' {
		bridge_resp := app.feishu_card_bridge_dispatch_callback(app_name, trace_id, summary,
			payload) or {
			log.error('[feishu] ❌ bridge callback dispatch failed: ${err}')
			ctx.res.set_status(http.status_from_int(502))
			return ctx.text(json.encode(AdminErrorResponse{
				error: 'feishu_callback_bridge_error'
			}))
		}
		for name, value in bridge_resp.headers {
			if name.to_lower() == 'content-type' {
				continue
			}
			ctx.set_custom_header(name, value) or {} // safe to ignore: client may have disconnected
		}
		ctx.res.set_status(http.status_from_int(if bridge_resp.status > 0 {
			bridge_resp.status
		} else {
			200
		}))
		ctype := bridge_resp.headers['content-type'] or { 'application/json; charset=utf-8' }
		ctx.set_content_type(ctype)
		app.emit('http.request', {
			'method':     'POST'
			'path':       '/callbacks/feishu'
			'status':     '${if bridge_resp.status > 0 { bridge_resp.status } else { 200 }}'
			'request_id': req_id
			'trace_id':   trace_id
			'provider':   'feishu'
			'instance':   app_name
			'callback':   '${summary.event_type}.bridge'
		})
		return ctx.text(bridge_resp.body)
	}
	if app.has_websocket_upstream_logic_executor()
		&& feishu_runtime_should_dispatch_upstream(summary) {
		activity_id := if summary.event_id != '' {
			summary.event_id
		} else {
			'callback-${time.now().unix_micro()}'
		}
		mut activity_snapshot := WebSocketUpstreamActivitySnapshot{
			provider:    websocket_upstream_provider_feishu
			instance:    app_name
			trace_id:    trace_id
			activity_id: activity_id
			event_type:  summary.event_type
			message_id:  summary.message_id
			target_type: summary.target_type
			target:      summary.target
			payload:     payload
			received_at: time.now().unix()
			recorded_at: time.now().unix()
		}
		outcome := app.kernel_dispatch_websocket_upstream_handled(app.kernel_websocket_upstream_dispatch_request_with_event(summary.event_kind,
			activity_id, websocket_upstream_provider_feishu, app_name, trace_id,
			summary.event_type, summary.message_id, summary.target, summary.target_type, payload,
			time.now().unix(), {
			'action':            'callback'
			'event_id':          summary.event_id
			'event_kind':        summary.event_kind
			'chat_type':         summary.chat_type
			'message_type':      summary.message_type
			'open_message_id':   summary.open_message_id
			'root_id':           summary.root_id
			'parent_id':         summary.parent_id
			'create_time':       summary.create_time
			'sender_id':         summary.sender_id
			'sender_id_type':    summary.sender_id_type
			'sender_tenant_key': summary.sender_tenant_key
			'action_tag':        summary.action_tag
			'action_value':      summary.action_value
			'token':             summary.token
		})) or {
			activity_snapshot.worker_error = err.msg()
			activity_snapshot.error_class = 'transport_error'
			app.websocket_upstream_record_activity(activity_snapshot)
			ctx.res.set_status(http.status_from_int(502))
			return ctx.text(json.encode(AdminErrorResponse{
				error: 'feishu_callback_worker_transport_error'
			}))
		}
		resp := outcome.response
		if resp.error != '' {
			activity_snapshot.worker_error = resp.error
			activity_snapshot.error_class = resp.error_class
			app.websocket_upstream_record_activity(activity_snapshot)
			ctx.res.set_status(http.status_from_int(502))
			return ctx.text(json.encode(AdminErrorResponse{
				error: 'feishu_callback_worker_error'
			}))
		}
		activity_snapshot.worker_handled = resp.handled
		activity_snapshot.commands = outcome.command_snapshots
		activity_snapshot.command_error = outcome.command_error
		app.websocket_upstream_record_activity(activity_snapshot)
	}
	app.emit('http.request', {
		'method':     'POST'
		'path':       '/callbacks/feishu'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'provider':   'feishu'
		'instance':   app_name
		'callback':   summary.event_type
	})
	return ctx.text(json.encode(FeishuCallbackAckResponse{
		code: 0
		msg:  'ok'
	}))
}

@['/admin/runtime/feishu/messages'; post]
pub fn (mut app App) admin_runtime_feishu_send(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime/feishu/messages' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	req := json.decode(FeishuRuntimeSendMessageRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(FeishuRuntimeSendMessageResult{
			ok:    false
			error: 'invalid_json'
		}))
	}
	result := app.feishu_runtime_send_message(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(FeishuRuntimeSendMessageResult{
			ok:    false
			error: err.msg()
		}))
	}
	app.emit('http.request', {
		'method':     'POST'
		'path':       '/admin/runtime/feishu/messages'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(json.encode(result))
}

@['/gateway/feishu/messages'; post]
pub fn (mut app App) gateway_feishu_send(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/gateway/feishu/messages' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.api_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	req := json.decode(FeishuRuntimeSendMessageRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(FeishuRuntimeSendMessageResult{
			ok:    false
			error: 'invalid_json'
		}))
	}
	result := app.feishu_runtime_send_message(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(FeishuRuntimeSendMessageResult{
			ok:    false
			error: err.msg()
		}))
	}
	app.emit('http.request', {
		'method':     'POST'
		'path':       '/gateway/feishu/messages'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'gateway'
	})
	return ctx.text(json.encode(result))
}
