module main

import json
import crypto.sha256
import net.http
import time
import toml

fn new_feishu_http_test_app() App {
	return App{
		feishu_enabled:       true
		feishu_open_base_url: 'https://open.feishu.test/open-apis'
		feishu_apps: {
			'main': FeishuAppConfig{
				app_id:             'cli_main'
				app_secret:         'sec_main'
				verification_token: 'verify_main'
				encrypt_key:        'encrypt_main'
			}
		}
		feishu_runtime: map[string]FeishuProviderRuntime{}
		feishu_buffers: map[string]FeishuStreamBuffer{}
		feishu_http_test_stub: true
		feishu_http_test_delay_ms: 40
	}
}

fn feishu_test_concurrent_fetch(app &App, url string) int {
	resp := feishu_runtime_http_fetch_locked(app, http.FetchConfig{
		url:    url
		method: .get
	}) or {
		panic(err)
	}
	return resp.status_code
}

fn test_feishu_runtime_proto_roundtrip() {
	frame := FeishuRuntimeProtoFrame{
		seq_id:           42
		method:           feishu_runtime_frame_type_data
		headers:          [
			FeishuRuntimeProtoHeader{
				key:   feishu_runtime_header_type
				value: feishu_runtime_message_data
			},
			FeishuRuntimeProtoHeader{
				key:   feishu_runtime_header_trace
				value: 'trace-1'
			},
		]
		payload_encoding: 'json'
		payload_type:     'application/json'
		payload:          '{"ok":true}'.bytes()
		log_id_str:       'log-1'
	}
	encoded := feishu_runtime_proto_frame_encode(frame)
	decoded := feishu_runtime_proto_frame_decode(encoded) or { panic(err) }
	headers := feishu_runtime_header_map(decoded.headers)
	assert decoded.seq_id == 42
	assert decoded.method == feishu_runtime_frame_type_data
	assert headers[feishu_runtime_header_type] == feishu_runtime_message_data
	assert headers[feishu_runtime_header_trace] == 'trace-1'
	assert decoded.payload.bytestr() == '{"ok":true}'
	assert decoded.log_id_str == 'log-1'
}

fn test_feishu_runtime_build_ack_preserves_message_type() {
	frame := FeishuRuntimeProtoFrame{
		seq_id:    42
		log_id:    9
		service:   17
		method:    feishu_runtime_frame_type_data
		log_id_str: 'log-9'
		headers:   [
			FeishuRuntimeProtoHeader{
				key:   feishu_runtime_header_type
				value: feishu_runtime_message_event
			},
			FeishuRuntimeProtoHeader{
				key:   feishu_runtime_header_seq
				value: '42'
			},
			FeishuRuntimeProtoHeader{
				key:   feishu_runtime_header_trace
				value: 'trace-1'
			},
		]
	}
	ack := feishu_runtime_build_ack(frame)
	ack_headers := feishu_runtime_header_map(ack.headers)
	assert ack.seq_id == 42
	assert ack.log_id == 9
	assert ack.service == 17
	assert ack.log_id_str == 'log-9'
	assert ack_headers[feishu_runtime_header_type] == feishu_runtime_message_event
	assert ack_headers[feishu_runtime_header_biz_rt] == '0'
	assert ack.payload.bytestr().contains('"code":200')
}

fn test_feishu_runtime_build_pong_preserves_frame_metadata() {
	frame := FeishuRuntimeProtoFrame{
		seq_id:    7
		log_id:    3
		service:   11
		method:    feishu_runtime_frame_type_control
		log_id_str: 'log-3'
		payload_encoding: 'json'
		payload_type:     'application/json'
		payload:          '{"ping":1}'.bytes()
		headers:   [
			FeishuRuntimeProtoHeader{
				key:   feishu_runtime_header_type
				value: feishu_runtime_message_ping
			},
			FeishuRuntimeProtoHeader{
				key:   feishu_runtime_header_seq
				value: '7'
			},
		]
	}
	pong := feishu_runtime_build_pong(frame)
	pong_headers := feishu_runtime_header_map(pong.headers)
	assert pong.seq_id == 7
	assert pong.log_id == 3
	assert pong.service == 11
	assert pong.log_id_str == 'log-3'
	// runtime encoder emits pong as protocol method=3 (control pong frame).
	assert pong.method == 3
	assert pong_headers[feishu_runtime_header_type] == feishu_runtime_message_pong
	assert pong.payload.bytestr() == '{"ping":1}'
}

fn test_feishu_runtime_event_summary() {
	summary := feishu_runtime_event_summary('{"header":{"event_type":"im.message.receive_v1"},"event":{"sender":{"sender_id":{"open_id":"ou_sender"},"tenant_key":"tenant_a"},"message":{"message_id":"om_x","message_type":"text","chat_id":"oc_y","chat_type":"group","root_id":"om_root","parent_id":"om_parent","create_time":"1710000000"}}}')
	assert summary.event_kind == 'message'
	assert summary.event_type == 'im.message.receive_v1'
	assert summary.message_id == 'om_x'
	assert summary.message_type == 'text'
	assert summary.chat_id == 'oc_y'
	assert summary.target_type == 'chat_id'
	assert summary.target == 'oc_y'
	assert summary.chat_type == 'group'
	assert summary.root_id == 'om_root'
	assert summary.parent_id == 'om_parent'
	assert summary.create_time == '1710000000'
	assert summary.sender_id == 'ou_sender'
	assert summary.sender_id_type == 'open_id'
	assert summary.sender_tenant_key == 'tenant_a'
}

fn test_feishu_runtime_message_type_recognition() {
	assert feishu_runtime_message_event in [feishu_runtime_message_data, feishu_runtime_message_event, feishu_runtime_message_card]
	assert feishu_runtime_message_card in [feishu_runtime_message_data, feishu_runtime_message_event, feishu_runtime_message_card]
}

fn test_feishu_runtime_action_event_summary() {
	summary := feishu_runtime_event_summary('{"schema":"2.0","header":{"event_id":"evt_action_1","event_type":"card.action.trigger"},"event":{"open_message_id":"om_open_1","action":{"tag":"button","value":{"action":"approve","ticket_id":"t_1"}}},"token":"verification_token","tenant_key":"tenant_action"}')
	assert summary.event_kind == 'action'
	assert summary.event_id == 'evt_action_1'
	assert summary.event_type == 'card.action.trigger'
	assert summary.target_type == 'open_message_id'
	assert summary.target == 'om_open_1'
	assert summary.open_message_id == 'om_open_1'
	assert summary.action_tag == 'button'
	assert summary.action_value.contains('approve')
	assert summary.token == 'verification_token'
	assert summary.sender_tenant_key == 'tenant_action'
}

fn test_feishu_runtime_callback_challenge_and_token_validation() {
	payload := '{"type":"url_verification","challenge":"challenge_value","token":"verify_main"}'
	assert feishu_runtime_callback_challenge(payload) == 'challenge_value'
	app := App{
		feishu_enabled: true
		feishu_apps: {
			'main': FeishuAppConfig{
				app_id:             'cli_main'
				app_secret:         'sec_main'
				verification_token: 'verify_main'
				encrypt_key:        'encrypt_main'
			}
		}
	}
	assert app.feishu_runtime_callback_token_valid('main', payload)
	assert !app.feishu_runtime_callback_token_valid('main',
		'{"type":"url_verification","challenge":"challenge_value","token":"wrong"}')
}

fn test_feishu_runtime_callback_signature_validation() {
	payload := '{"encrypt":"cipher_payload"}'
	headers := {
		'x-lark-request-timestamp': '1710000000'
		'x-lark-request-nonce':     'nonce-1'
	}
	signature := sha256.sum('1710000000nonce-1encrypt_key_1${payload}'.bytes()).hex().to_lower()
	mut signed_headers := headers.clone()
	signed_headers['x-lark-signature'] = signature
	assert feishu_runtime_callback_signature_valid(signed_headers, 'encrypt_key_1', payload)
	assert !feishu_runtime_callback_signature_valid(signed_headers, 'wrong_key', payload)
}

fn test_decode_feishu_multi_app_config() {
	doc := toml.parse_text('
[feishu]
enabled = true
open_base_url = "https://open.feishu.cn/open-apis"

[feishu.main]
app_id = "cli_main"
app_secret = "sec_main"
verification_token = "verify_main"
encrypt_key = "encrypt_main"

[feishu.openclaw]
app_id = "cli_openclaw"
app_secret = "sec_openclaw"
verification_token = "verify_openclaw"
encrypt_key = "encrypt_openclaw"
') or {
		panic(err)
	}
	mut cfg := default_vhttpd_config()
	decode_feishu_config(doc, mut cfg) or { panic(err) }
	assert cfg.feishu.apps['main']!.app_id == 'cli_main'
	assert cfg.feishu.apps['main']!.app_secret == 'sec_main'
	assert cfg.feishu.apps['main']!.verification_token == 'verify_main'
	assert cfg.feishu.apps['main']!.encrypt_key == 'encrypt_main'
	assert cfg.feishu.apps['openclaw']!.app_id == 'cli_openclaw'
	assert cfg.feishu.apps['openclaw']!.app_secret == 'sec_openclaw'
	assert cfg.feishu.apps['openclaw']!.verification_token == 'verify_openclaw'
	assert cfg.feishu.apps['openclaw']!.encrypt_key == 'encrypt_openclaw'
}

fn test_feishu_runtime_build_message_content() {
	text_content := feishu_runtime_build_message_content('text', '', 'pong', map[string]string{}) or {
		panic(err)
	}
	assert text_content == '{"text":"pong"}'
	image_content := feishu_runtime_build_message_content('image', '', '', {
		'image_key': 'img_v2_123'
	}) or { panic(err) }
	assert image_content == '{"image_key":"img_v2_123"}'
	media_content := feishu_runtime_build_message_content('media', '', '', {
		'file_key':  'file_v2_1'
		'image_key': 'img_v2_1'
		'file_name': 'demo.mp4'
		'duration':  '3000'
	}) or { panic(err) }
	assert media_content.contains('"file_key":"file_v2_1"')
	assert media_content.contains('"image_key":"img_v2_1"')
	assert media_content.contains('"file_name":"demo.mp4"')
	assert media_content.contains('"duration":"3000"')
	if _ := feishu_runtime_build_message_content('post', '', '', map[string]string{}) {
		assert false
	} else {
		assert err.msg().contains('missing raw content')
	}
}

fn test_feishu_runtime_update_http_method() {
	assert feishu_runtime_update_http_method('text') == .put
	assert feishu_runtime_update_http_method('post') == .put
	assert feishu_runtime_update_http_method('interactive') == .patch
}

fn test_feishu_runtime_http_fetch_serializes_parallel_requests() {
	mut app := new_feishu_http_test_app()
	app_ptr := &app
	start := time.now()
	t1 := spawn feishu_test_concurrent_fetch(app_ptr, 'https://open.feishu.test/open-apis/a')
	t2 := spawn feishu_test_concurrent_fetch(app_ptr, 'https://open.feishu.test/open-apis/b')
	t3 := spawn feishu_test_concurrent_fetch(app_ptr, 'https://open.feishu.test/open-apis/c')
	assert t1.wait() == 200
	assert t2.wait() == 200
	assert t3.wait() == 200
	elapsed_ms := time.since(start).milliseconds()
	assert app.feishu_http_test_calls == 3
	assert elapsed_ms >= 100
}

fn test_feishu_runtime_send_and_update_share_one_http_lane() {
	mut app := new_feishu_http_test_app()
	send_result := app.feishu_runtime_send_message(FeishuRuntimeSendMessageRequest{
		app:             'main'
		receive_id_type: 'chat_id'
		receive_id:      'oc_1'
		msg_type:        'interactive'
		content:         '{"elements":[{"tag":"markdown","content":"hello 1"}]}'
	}) or {
		panic(err)
	}
	update_result := app.feishu_runtime_update_message(FeishuRuntimeUpdateMessageRequest{
		app:        'main'
		message_id: 'om_2'
		msg_type:   'interactive'
		content:    '{"elements":[{"tag":"markdown","content":"update 2"}]}'
	}) or {
		panic(err)
	}
	assert send_result.message_id.starts_with('om_test_')
	assert update_result.message_id == 'om_updated'
	assert app.feishu_http_test_calls >= 3
	assert app.feishu_http_test_inflight == 0
}

fn test_feishu_runtime_normalize_streaming_send_wraps_text_as_interactive_card() {
	req := WebSocketUpstreamSendRequest{
		provider:     'feishu'
		instance:     'main'
		target_type:  'chat_id'
		target:       'oc_demo'
		message_type: 'text'
		text:         'hello stream'
	}
	normalized := feishu_runtime_normalize_streaming_send(req)
	assert normalized.message_type == 'interactive'
	assert normalized.content.contains('"elements"')
	assert normalized.content.contains('hello stream')
	assert normalized.text == ''
	assert normalized.content_fields.len == 0
}

fn test_feishu_runtime_normalize_streaming_send_preserves_existing_interactive_card() {
	req := WebSocketUpstreamSendRequest{
		provider:     'feishu'
		instance:     'main'
		target_type:  'chat_id'
		target:       'oc_demo'
		message_type: 'interactive'
		content:      '{"elements":[{"tag":"markdown","content":"ready"}]}'
	}
	normalized := feishu_runtime_normalize_streaming_send(req)
	assert normalized.message_type == 'interactive'
	assert normalized.content == req.content
}

fn test_feishu_runtime_delay_update_card_body() {
	body := feishu_runtime_delay_update_card_body('callback-token-1',
		'{"config":{"wide_screen_mode":true},"elements":[{"tag":"markdown","content":"approved"}]}') or {
		panic(err)
	}
	assert body.contains('"token":"callback-token-1"')
	assert body.contains('"card"')
	assert body.contains('"approved"')
}

fn test_feishu_runtime_root_base() {
	assert feishu_runtime_root_base('https://open.feishu.cn/open-apis') == 'https://open.feishu.cn'
	assert feishu_runtime_root_base('https://open.feishu.cn/open-apis/') == 'https://open.feishu.cn'
	assert feishu_runtime_root_base('https://open.feishu.cn') == 'https://open.feishu.cn'
}

fn test_feishu_runtime_ws_endpoint_urls() {
	urls := feishu_runtime_ws_endpoint_urls('https://open.feishu.cn/open-apis')
	assert urls.len == 2
	assert urls[0] == 'https://open.feishu.cn/open-apis/callback/ws/endpoint'
	assert urls[1] == 'https://open.feishu.cn/callback/ws/endpoint'
	root_urls := feishu_runtime_ws_endpoint_urls('https://open.feishu.cn')
	assert root_urls == ['https://open.feishu.cn/callback/ws/endpoint']
}

fn test_feishu_runtime_ws_endpoint_body() {
	body := feishu_runtime_ws_endpoint_body('cli_main', 'sec_main')
	assert body.contains('"AppID":"cli_main"')
	assert body.contains('"AppSecret":"sec_main"')
}

fn test_feishu_runtime_ws_endpoint_response_decode() {
	decoded := json.decode(FeishuRuntimeWsEndpointResponse,
		'{"code":0,"msg":"","data":{"URL":"wss://msg-frontier.feishu.cn/ws/v2?ticket=test","ClientConfig":{"PingInterval":90,"ReconnectInterval":90,"ReconnectNonce":25,"ReconnectCount":-1}}}') or {
		panic(err)
	}
	assert decoded.code == 0
	assert decoded.data.url == 'wss://msg-frontier.feishu.cn/ws/v2?ticket=test'
	assert decoded.data.client_config.ping_interval == 90
}

fn test_feishu_runtime_note_client_config() {
	mut app := App{
		feishu_enabled: true
		feishu_apps: {
			'main': FeishuAppConfig{
				app_id:     'cli_main'
				app_secret: 'sec_main'
			}
		}
		feishu_runtime: map[string]FeishuProviderRuntime{}
	}
	app.feishu_runtime_note_client_config('main', FeishuRuntimeClientConfig{
		ping_interval:      15
		reconnect_interval: 90
	})
	assert app.feishu_runtime_snapshot().apps[0].ping_interval_seconds == 15
}

fn test_admin_feishu_runtime_chats_snapshot_dedupes_by_instance_and_chat() {
	mut app := App{
		feishu_runtime: {
			'main': FeishuProviderRuntime{
				name: 'main'
				recent_events: [
					FeishuRuntimeEventSnapshot{
						chat_id:      'oc_chat_a'
						chat_type:    'p2p'
						event_type:   'im.message.receive_v1'
						message_id:   'om_1'
						message_type: 'text'
						sender_id:    'ou_1'
						create_time:  '1710000001'
						received_at:  1710000001
					},
					FeishuRuntimeEventSnapshot{
						chat_id:      'oc_chat_a'
						chat_type:    'p2p'
						event_type:   'im.message.receive_v1'
						message_id:   'om_2'
						message_type: 'text'
						sender_id:    'ou_2'
						create_time:  '1710000002'
						received_at:  1710000002
					},
					FeishuRuntimeEventSnapshot{
						chat_id:      'oc_chat_b'
						chat_type:    'group'
						event_type:   'im.message.receive_v1'
						message_id:   'om_3'
						message_type: 'image'
						sender_id:    'ou_3'
						create_time:  '1710000003'
						received_at:  1710000003
					},
				]
			}
			'mac': FeishuProviderRuntime{
				name: 'mac'
				recent_events: [
					FeishuRuntimeEventSnapshot{
						chat_id:      'oc_chat_a'
						chat_type:    'group'
						event_type:   'im.message.receive_v1'
						message_id:   'om_4'
						message_type: 'post'
						sender_id:    'ou_4'
						create_time:  '1710000004'
						received_at:  1710000004
					},
				]
			}
		}
	}
	snapshot := app.feishu_runtime_chats_snapshot(10, 0, '', '', '')
	assert snapshot.returned_count == 3
	assert snapshot.chats[0].instance == 'mac'
	assert snapshot.chats[0].chat_id == 'oc_chat_a'
	assert snapshot.chats[1].instance == 'main'
	assert snapshot.chats[1].chat_id == 'oc_chat_b'
	assert snapshot.chats[2].instance == 'main'
	assert snapshot.chats[2].chat_id == 'oc_chat_a'
	assert snapshot.chats[2].last_message_id == 'om_2'
	assert snapshot.chats[2].seen_count == 2
	filtered := app.feishu_runtime_chats_snapshot(10, 0, 'main', 'group', '')
	assert filtered.returned_count == 1
	assert filtered.chats[0].chat_id == 'oc_chat_b'
}

fn test_admin_feishu_runtime_chats_snapshot_json_shape() {
	mut app := App{
		feishu_runtime: {
			'main': FeishuProviderRuntime{
				name: 'main'
				recent_events: [
					FeishuRuntimeEventSnapshot{
						chat_id:      'oc_chat_a'
						chat_type:    'p2p'
						event_type:   'im.message.receive_v1'
						message_id:   'om_1'
						message_type: 'text'
						sender_id:    'ou_1'
						create_time:  '1710000001'
						received_at:  1710000001
					},
				]
			}
		}
	}
	encoded := json.encode(app.feishu_runtime_chats_snapshot(10, 0, '', '', ''))
	assert encoded.contains('"chats"')
	assert encoded.contains('"instance"')
	assert encoded.contains('"chat_id"')
	assert encoded.contains('"chat_type"')
	assert encoded.contains('"target_type"')
	assert encoded.contains('"last_message_id"')
	assert encoded.contains('"seen_count"')
}

fn test_feishu_runtime_resolve_named_apps() {
	app := App{
		feishu_enabled: true
		feishu_apps: {
			'main': FeishuAppConfig{
				app_id:     'cli_main'
				app_secret: 'sec_main'
			}
			'openclaw': FeishuAppConfig{
				app_id:     'cli_openclaw'
				app_secret: 'sec_openclaw'
			}
		}
	}
	assert app.feishu_runtime_default_app_name() == 'main'
	assert app.feishu_runtime_app_names() == ['main', 'openclaw']
	assert app.feishu_runtime_resolve_app_name('')! == 'main'
	assert app.feishu_runtime_resolve_app_name('openclaw')! == 'openclaw'
	assert app.websocket_upstream_provider_enabled(websocket_upstream_provider_feishu, 'main')
	assert app.websocket_upstream_provider_enabled(websocket_upstream_provider_feishu, 'openclaw')
	assert !app.websocket_upstream_provider_enabled(websocket_upstream_provider_feishu, 'missing')
}

fn test_websocket_upstream_activity_snapshot_filters_and_limit() {
	mut app := App{
		websocket_upstream_recent_dispatch_limit: 2
		websocket_upstream_recent_activities: []WebSocketUpstreamActivitySnapshot{}
	}
	app.websocket_upstream_record_activity(WebSocketUpstreamActivitySnapshot{
		provider:    'feishu'
		instance:    'main'
		activity_id: 'a1'
		received_at: 10
		recorded_at: 10
	})
	app.websocket_upstream_record_activity(WebSocketUpstreamActivitySnapshot{
		provider:    'feishu'
		instance:    'openclaw'
		activity_id: 'a2'
		received_at: 20
		recorded_at: 20
	})
	app.websocket_upstream_record_activity(WebSocketUpstreamActivitySnapshot{
		provider:    'feishu'
		instance:    'main'
		activity_id: 'a3'
		received_at: 30
		recorded_at: 30
	})
	snapshot := app.admin_websocket_upstream_activities_snapshot(10, 0, 'feishu', '')
	assert snapshot.returned_count == 2
	assert snapshot.activities.len == 2
	assert snapshot.activities[0].activity_id == 'a3'
	assert snapshot.activities[1].activity_id == 'a2'
	filtered := app.admin_websocket_upstream_activities_snapshot(10, 0, 'feishu', 'main')
	assert filtered.returned_count == 1
	assert filtered.activities[0].activity_id == 'a3'
}

fn test_execute_websocket_upstream_commands_skips_and_reports_errors() {
	mut app := App{
		feishu_apps: {
			'main': FeishuAppConfig{
				app_id:     'cli_main'
				app_secret: 'sec_main'
			}
		}
	}
	snapshots, last_error := app.execute_websocket_upstream_commands('dispatch-test', [
		WorkerWebSocketUpstreamCommand{
			event:    'noop'
			provider: 'feishu'
			instance: 'main'
			metadata: {
				'source': 'unit-test'
			}
		},
		WorkerWebSocketUpstreamCommand{
			event:    'send'
			provider: 'unknown'
			instance: 'main'
			target:   'oc_x'
		},
	])
	assert snapshots.len == 2
	assert snapshots[0].status == 'skipped'
	assert snapshots[0].error == 'unsupported_command_event'
	assert snapshots[0].metadata['source'] == 'unit-test'
	assert snapshots[0].source_activity_id == 'dispatch-test'
	assert snapshots[0].source_command_index == 0
	assert snapshots[1].status == 'error'
	assert snapshots[1].error.contains('unknown websocket upstream provider')
	assert snapshots[1].source_activity_id == 'dispatch-test'
	assert snapshots[1].source_command_index == 1
	assert last_error.contains('unknown websocket upstream provider')
}

fn test_execute_websocket_upstream_commands_preserves_content_fields() {
	mut app := App{
		fixture_websocket_runtime: map[string]FixtureWebSocketUpstreamRuntime{}
	}
	snapshots, last_error := app.execute_websocket_upstream_commands('dispatch-content-fields', [
		WorkerWebSocketUpstreamCommand{
			event:        'send'
			provider:     websocket_upstream_provider_fixture
			instance:     'demo'
			target_type:  'fixture_target'
			target:       'room-1'
			message_type: 'image'
			content_fields: {
				'image_key': 'img_v2_123'
			}
			metadata: {
				'source': 'unit-test'
			}
		},
	])
	assert last_error == ''
	assert snapshots.len == 1
	assert snapshots[0].status == 'sent'
	assert snapshots[0].message_type == 'image'
	assert snapshots[0].content_fields['image_key'] == 'img_v2_123'
	assert snapshots[0].metadata['source'] == 'unit-test'
}

fn test_execute_websocket_upstream_commands_updates_fixture_messages() {
	mut app := App{
		fixture_websocket_runtime: map[string]FixtureWebSocketUpstreamRuntime{}
	}
	snapshots, last_error := app.execute_websocket_upstream_commands('dispatch-update', [
		WorkerWebSocketUpstreamCommand{
			event:        'update'
			provider:     websocket_upstream_provider_fixture
			instance:     'demo'
			target_type:  'message_id'
			target:       'fixture-msg-1'
			message_type: 'interactive'
			content:      '{"type":"template","data":{"template_id":"ctp_demo"}}'
			metadata: {
				'source': 'unit-test'
			}
		},
	])
	assert last_error == ''
	assert snapshots.len == 1
	assert snapshots[0].status == 'updated'
	assert snapshots[0].message_id == 'fixture-msg-1'
	assert snapshots[0].event == 'update'
	assert snapshots[0].metadata['source'] == 'unit-test'
}

fn test_admin_websocket_upstream_activities_snapshot_json_shape() {
	mut app := App{
		websocket_upstream_recent_dispatch_limit: 10
		websocket_upstream_recent_activities: []WebSocketUpstreamActivitySnapshot{}
	}
	app.websocket_upstream_record_activity(WebSocketUpstreamActivitySnapshot{
		provider:       'feishu'
		instance:       'main'
		trace_id:       'trace-1'
		activity_id:    'activity-1'
		event_type:     'im.message.receive_v1'
		message_id:     'om_1'
		target_type:    'chat_id'
		target:         'oc_1'
		payload:        '{"ok":true}'
		received_at:    100
		worker_handled: true
		command_error:  ''
		commands: [
			WebSocketUpstreamCommandActivity{
				event:        'send'
				provider:     'feishu'
				instance:     'main'
				target_type:  'chat_id'
				target:       'oc_1'
				message_type: 'text'
				text:         'pong'
				metadata: {
					'source': 'dispatch-test'
				}
				source_activity_id: 'activity-1'
				source_command_index: 0
				status:       'sent'
				message_id:   'om_reply'
				executed_at:  101
			},
		]
		recorded_at: 102
	})
	encoded := json.encode(app.admin_websocket_upstream_activities_snapshot(10, 0, 'feishu',
		'main'))
	assert encoded.contains('"activities"')
	assert encoded.contains('"provider":"feishu"')
	assert encoded.contains('"instance":"main"')
	assert encoded.contains('"activity_id":"activity-1"')
	assert encoded.contains('"worker_handled":true')
	assert encoded.contains('"commands"')
	assert encoded.contains('"status":"sent"')
	assert encoded.contains('"message_id":"om_reply"')
	assert encoded.contains('"source":"dispatch-test"')
	assert encoded.contains('"source_activity_id":"activity-1"')
	assert encoded.contains('"source_command_index":0')
}

fn test_fixture_websocket_provider_emit_and_send() {
	mut app := App{
		fixture_websocket_runtime: map[string]FixtureWebSocketUpstreamRuntime{}
		websocket_upstream_recent_dispatch_limit: 10
		websocket_upstream_recent_activities: []WebSocketUpstreamActivitySnapshot{}
	}
	assert app.websocket_upstream_provider_enabled(websocket_upstream_provider_fixture, 'demo')
	send_result := app.websocket_upstream_send(WebSocketUpstreamSendRequest{
		provider:     websocket_upstream_provider_fixture
		instance:     'demo'
		target_type:  'fixture_target'
		target:       'room-1'
		message_type: 'text'
		text:         'hello'
	}) or { panic(err) }
	assert send_result.ok
	assert send_result.provider == websocket_upstream_provider_fixture
	assert send_result.instance == 'demo'
	assert send_result.message_id.starts_with('fixture-msg-')
	dispatch := app.fixture_websocket_emit(WebSocketUpstreamFixtureEmitRequest{
		instance:    'demo'
		trace_id:    'trace-fixture'
		event_type:  'fixture.message'
		message_id:  'fixture-1'
		target_type: 'fixture_target'
		target:      'room-1'
		payload:     '{"text":"hello"}'
		metadata: {
			'source': 'unit-test'
		}
	}) or { panic(err) }
	assert dispatch.provider == websocket_upstream_provider_fixture
	assert dispatch.instance == 'demo'
	assert dispatch.message_id == 'fixture-1'
	assert dispatch.target == 'room-1'
	events := app.admin_websocket_upstream_events_snapshot(10, 0, websocket_upstream_provider_fixture,
		'demo')
	assert events.returned_count == 1
	assert events.events[0].provider == websocket_upstream_provider_fixture
	assert events.events[0].message_id == 'fixture-1'
	assert events.events[0].target_type == 'fixture_target'
	assert events.events[0].metadata['source'] == 'unit-test'
	upstreams := app.admin_websocket_upstreams_snapshot(false, 10, 0, websocket_upstream_provider_fixture,
		'demo')
	assert upstreams.returned_count == 1
	assert upstreams.sessions[0].provider == websocket_upstream_provider_fixture
	assert upstreams.sessions[0].instance == 'demo'
}

fn test_admin_websocket_upstream_events_snapshot_projects_feishu_metadata() {
	mut app := App{
		feishu_enabled: true
		feishu_apps: {
			'main': FeishuAppConfig{
				app_id:     'cli_main'
				app_secret: 'sec_main'
			}
		}
		feishu_runtime: {
			'main': FeishuProviderRuntime{
				name: 'main'
				recent_events: [
					FeishuRuntimeEventSnapshot{
						seq_id:            'seq-1'
						trace_id:          'trace-1'
						action:            'im.message.receive_v1'
						event_id:          'evt-1'
						event_kind:        'message'
						event_type:        'im.message.receive_v1'
						message_id:        'om_1'
						message_type:      'text'
						chat_id:           'oc_1'
						chat_type:         'group'
						target_type:       'chat_id'
						target:            'oc_1'
						open_message_id:   ''
						root_id:           'om_root'
						parent_id:         'om_parent'
						create_time:       '1710000000'
						sender_id:         'ou_sender'
						sender_id_type:    'open_id'
						sender_tenant_key: 'tenant_a'
						action_tag:        ''
						action_value:      ''
						token:             'token_a'
						received_at:       100
						payload:           '{"ok":true}'
					},
				]
			}
		}
	}
	events := app.admin_websocket_upstream_events_snapshot(10, 0, websocket_upstream_provider_feishu,
		'main')
	assert events.returned_count == 1
	assert events.events[0].provider == websocket_upstream_provider_feishu
	assert events.events[0].target == 'oc_1'
	assert events.events[0].metadata['event_id'] == 'evt-1'
	assert events.events[0].metadata['event_kind'] == 'message'
	assert events.events[0].metadata['message_type'] == 'text'
	assert events.events[0].metadata['chat_type'] == 'group'
	assert events.events[0].metadata['token'] == 'token_a'
	assert events.events[0].metadata['root_id'] == 'om_root'
	assert events.events[0].metadata['parent_id'] == 'om_parent'
	assert events.events[0].metadata['create_time'] == '1710000000'
	assert events.events[0].metadata['sender_id'] == 'ou_sender'
	assert events.events[0].metadata['sender_id_type'] == 'open_id'
	assert events.events[0].metadata['sender_tenant_key'] == 'tenant_a'
}

fn test_feishu_update_message_rejects_non_interactive_message_id_updates_locally() {
	mut app := App{
		feishu_enabled: true
		feishu_apps: {
			'main': FeishuAppConfig{
				app_id: 'cli_main'
			}
		}
		feishu_runtime: {
			'main': FeishuProviderRuntime{
				name: 'main'
			}
		}
	}
	app.feishu_runtime_update_message(FeishuRuntimeUpdateMessageRequest{
		app:             'main'
		message_id:      'om_123'
		message_id_type: 'message_id'
		msg_type:        'text'
		text:            'hello'
	}) or {
		assert err.msg() == 'message_id-based feishu update only supports interactive cards'
		return
	}
	assert false
}
