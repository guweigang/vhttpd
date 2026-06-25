module main

import executor
import json
import log
import net.websocket as websock
import time
import upstream
import feishu

@[markused]
const feishu_runtime_frame_type_control = feishu.frame_type_control
const feishu_runtime_header_type = feishu.header_type
const feishu_runtime_header_seq = feishu.header_seq
const feishu_runtime_header_trace = feishu.header_trace
const feishu_runtime_message_ping = feishu.message_ping
const feishu_runtime_message_pong = feishu.message_pong
const feishu_runtime_message_data = feishu.message_data
const feishu_runtime_message_event = feishu.message_event
const feishu_runtime_message_card = feishu.message_card

fn (mut app App) feishu_provider_handle_binary_message(instance string, mut conn websock.Client, msg &websock.Message) ! {
	if msg.opcode != .binary_frame {
		return
	}
	app_name := app.providers.feishu.resolve_app_name(instance)!
	frame := feishu.RuntimeProtoFrame.decode(msg.payload) or {
		log.error('[feishu] ❌ proto decode failed: ${err}')
		return err
	}
	app.providers.feishu.note_frame(app_name)
	headers := feishu.RuntimeProtoHeader.to_map(frame.headers)
	msg_type := headers[feishu_runtime_header_type] or { '' }
	trace_id := headers[feishu_runtime_header_trace] or { '' }
	seq_id := headers[feishu_runtime_header_seq] or { '${frame.seq_id}' }
	if frame.method == 2 || msg_type == feishu_runtime_message_ping {
		pong := frame.pong()
		conn.write(pong.encode(), .binary_frame)!
		return
	}
	if frame.method == 3 || msg_type == feishu_runtime_message_pong {
		log.info('[feishu] 💓 heartbeat pong received')
		if frame.payload.len > 0 {
			cfg := json.decode(feishu.RuntimeClientConfig, frame.payload.bytestr()) or {
				feishu.RuntimeClientConfig{}
			}
			app.providers.feishu.note_client_config(app_name, cfg)
		}
		return
	}
	if msg_type !in [feishu_runtime_message_data, feishu_runtime_message_event,
		feishu_runtime_message_card] {
		return
	}
	payload := frame.payload.bytestr()
	summary := feishu.RuntimeEventSnapshot.summary_from_payload(payload)
	app.providers.feishu.push_event(app_name, feishu.RuntimeEventSnapshot{
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
	if app.providers.feishu.card_bridge_target_id.trim_space() != ''
		&& feishu.RuntimeEventSnapshot.should_dispatch_upstream(summary) {
		log.info('[feishu] 🔁 bridging upstream event to local runtime target=${app.providers.feishu.card_bridge_target_id} trace_id=${trace_id} event_type=${summary.event_type} message_id=${summary.message_id}')
		bridge_resp := app.providers.feishu_card_bridge_dispatch_callback(app_name, trace_id,
			summary, payload) or {
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
		&& feishu.RuntimeEventSnapshot.should_dispatch_upstream(summary) {
		log.info('[feishu] 📤 dispatching upstream event to logic executor kind=${app.logic_executor_kind()}')
		mut activity_snapshot := upstream.UpstreamActivitySnapshot{
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
	ack := frame.ack(ack_status, ack_headers, ack_data)
	conn.write(ack.encode(), .binary_frame)!
	app.providers.feishu.note_ack(app_name)
}
