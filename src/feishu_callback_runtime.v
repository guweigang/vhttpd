module main

import json
import log
import time
import upstream.transport
import upstream
import feishu
import veb

@['/callbacks/feishu'; post]
pub fn (mut app App) feishu_callback_default(mut ctx Context) veb.Result {
	return app.feishu_callback_by_app(mut ctx, '')
}

@['/callbacks/feishu/:app'; post]
pub fn (mut app App) feishu_callback(mut ctx Context, app_name string) veb.Result {
	return app.feishu_callback_by_app(mut ctx, app_name)
}

fn (mut app App) feishu_callback_by_app(mut ctx Context, raw_app string) veb.Result {
	default_path := if raw_app.trim_space() == '' {
		'/callbacks/feishu'
	} else {
		'/callbacks/feishu/${raw_app}'
	}
	req_ctx := FeishuHttpRequest.from_context(ctx, default_path)
	trace_id := req_ctx.trace_id
	app_name := app.providers.feishu.resolve_app_name(raw_app) or {
		return feishu_admin_error(req_ctx, mut app, mut ctx, 404, 'unknown_feishu_app')
	}
	app_cfg := app.providers.feishu.app_config(app_name) or {
		return feishu_admin_error(req_ctx, mut app, mut ctx, 404, 'unknown_feishu_app')
	}
	headers := transport.WorkerHttpRequestCodec.header_map_from_request(ctx.req)
	raw_payload := ctx.req.data
	if !feishu.CallbackChallengeResponse.signature_valid(headers, app_cfg.encrypt_key, raw_payload) {
		return feishu_admin_error(req_ctx, mut app, mut ctx, 403,
			'invalid_feishu_callback_signature')
	}
	payload := feishu.CallbackChallengeResponse.decrypt_payload(app_cfg.encrypt_key, raw_payload) or {
		return feishu_admin_error(req_ctx, mut app, mut ctx, 400,
			'invalid_feishu_callback_encryption')
	}
	challenge := feishu.CallbackChallengeResponse.challenge(payload)
	if challenge != '' {
		if !app.providers.feishu_runtime_callback_token_valid(app_name, payload) {
			return feishu_admin_error(req_ctx, mut app, mut ctx, 403,
				'invalid_feishu_callback_token')
		}
		return feishu_json_response(req_ctx, mut app, mut ctx, 200, json.encode(feishu.CallbackChallengeResponse{
			challenge: challenge
		}), 'challenge', app_name)
	}
	if !app.providers.feishu_runtime_callback_token_valid(app_name, payload) {
		return feishu_admin_error(req_ctx, mut app, mut ctx, 403, 'invalid_feishu_callback_token')
	}
	summary := feishu.RuntimeEventSnapshot.summary_from_payload(payload)
	app.providers.feishu.push_event(app_name, feishu.RuntimeEventSnapshot{
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
	callback_activity_id := if summary.event_id != '' {
		summary.event_id
	} else {
		'callback-${time.now().unix_micro()}'
	}
	app.dispatch_feishu_provider_ingress_event(app_name, trace_id, callback_activity_id,
		'callback', summary, payload)
	if summary.event_type == 'card.action.trigger'
		&& app.providers.feishu.card_bridge_target_id.trim_space() != '' {
		bridge_resp := app.providers.feishu_card_bridge_dispatch_callback(app_name, trace_id,
			summary, payload) or {
			log.error('[feishu] ❌ bridge callback dispatch failed: ${err}')
			return feishu_admin_error(req_ctx, mut app, mut ctx, 502,
				'feishu_callback_bridge_error')
		}
		mut bridge_headers := map[string]string{}
		for name, value in bridge_resp.headers {
			if name.to_lower() == 'content-type' {
				bridge_headers['content-type'] = value
				continue
			}
			bridge_headers[name] = value
		}
		if 'content-type' !in bridge_headers {
			bridge_headers['content-type'] = 'application/json; charset=utf-8'
		}
		return feishu_response(req_ctx, mut app, mut ctx, if bridge_resp.status > 0 {
			bridge_resp.status
		} else {
			200
		}, bridge_headers, bridge_resp.body, '${summary.event_type}.bridge', app_name)
	}
	if app.has_websocket_upstream_logic_executor()
		&& feishu.RuntimeEventSnapshot.should_dispatch_upstream(summary) {
		activity_id := callback_activity_id
		mut activity_snapshot := upstream.UpstreamActivitySnapshot{
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
			return feishu_admin_error(req_ctx, mut app, mut ctx, 502,
				'feishu_callback_worker_transport_error')
		}
		resp := outcome.response
		if resp.error != '' {
			activity_snapshot.worker_error = resp.error
			activity_snapshot.error_class = resp.error_class
			app.websocket_upstream_record_activity(activity_snapshot)
			return feishu_admin_error(req_ctx, mut app, mut ctx, 502,
				'feishu_callback_worker_error')
		}
		activity_snapshot.worker_handled = resp.handled
		activity_snapshot.commands = outcome.command_snapshots
		activity_snapshot.command_error = outcome.command_error
		app.websocket_upstream_record_activity(activity_snapshot)
	}
	return feishu_json_response(req_ctx, mut app, mut ctx, 200, json.encode(feishu.CallbackAckResponse{
		code: 0
		msg:  'ok'
	}), summary.event_type, app_name)
}
