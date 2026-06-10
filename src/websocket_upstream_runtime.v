module main

import admin
import codex
import command
import transport
import executor
import ws
import feishu
import json
import log
import net.http
import net.websocket
import time
import veb

// ── Type alias: main → ws ──
type WebSocketUpstreamSendRequest = ws.UpstreamSendRequest

const websocket_upstream_provider_feishu = 'feishu'
const websocket_upstream_provider_fixture = 'fixture'

// ── Builder: captures App closures ──

fn (mut app App) build_websocket_upstream_runtime_context() ws.UpstreamRuntimeContext {
	return ws.UpstreamRuntimeContext{
		enabled_fn:         fn [mut app] (provider string, instance string) bool {
			return app.websocket_upstream_provider_enabled(provider, instance)
		}
		reconnect_delay_fn: fn [mut app] (provider string, instance string) int {
			return app.websocket_upstream_provider_reconnect_delay_ms(provider, instance)
		}
		connecting_fn:      fn [mut app] (provider string, instance string) {
			app.websocket_upstream_provider_on_connecting(provider, instance)
		}
		pull_url_fn:        fn [mut app] (provider string, instance string) !string {
			return app.websocket_upstream_provider_pull_url(provider, instance)
		}
		connected_fn:       fn [mut app] (provider string, instance string, ws_url string) {
			app.websocket_upstream_provider_on_connected(provider, instance, ws_url)
			app.emit('websocket_upstream.connected', {
				'provider': provider
				'instance': instance
				'url':      ws_url
			})
		}
		disconnected_fn:    fn [mut app] (provider string, instance string, reason string) {
			app.websocket_upstream_provider_on_disconnected(provider, instance, reason)
		}
		handle_message_fn:  fn [mut app] (provider string, instance string, mut ws_client websocket.Client, msg &websocket.Message) ! {
			app.websocket_upstream_provider_handle_message(provider, instance, mut ws_client, msg)!
		}
		post_connect_fn:    fn [mut app] (provider string, instance string, ws_url string, mut client websocket.Client) {
			if provider == websocket_upstream_provider_feishu {
				mut feishu_app_ref := unsafe { &app }
				go feishu_runtime_ping_loop(mut feishu_app_ref, instance, ws_url, mut client)
			} else if provider == websocket_upstream_provider_codex {
				mut codex_app_ref := unsafe { &app }
				go codex_app_ref.codex_post_connect_handshake(instance, mut client)
				go codex.ping_loop(mut client)
			}
		}
	}
}

// ── Fixture helpers ──

fn (mut app App) fixture_websocket_emit(req ws.UpstreamFixtureEmitRequest) !ws.UpstreamActivitySnapshot {
	instance := if req.instance.trim_space() == '' { 'main' } else { req.instance.trim_space() }
	event_type := if req.event_type.trim_space() == '' {
		'fixture.message'
	} else {
		req.event_type.trim_space()
	}
	target_type := if req.target_type.trim_space() == '' {
		'fixture_target'
	} else {
		req.target_type.trim_space()
	}
	trace_id := if req.trace_id.trim_space() == '' {
		'fixture-trace-${time.now().unix_micro()}'
	} else {
		req.trace_id.trim_space()
	}
	message_id := if req.message_id.trim_space() == '' {
		'fixture-event-${time.now().unix_micro()}'
	} else {
		req.message_id.trim_space()
	}
	activity_id := 'fixture-activity-${time.now().unix_micro()}'
	received_at := time.now().unix()
	event := ws.UpstreamEventSnapshot{
		provider:    websocket_upstream_provider_fixture
		instance:    instance
		event_type:  event_type
		message_id:  message_id
		target:      req.target
		target_type: target_type
		trace_id:    trace_id
		received_at: received_at
		payload:     req.payload
		metadata:    req.metadata.clone()
	}
	app.ws_hub.fixture_push_event(instance, event, app.feishu.recent_event_limit)
	mut snapshot := ws.UpstreamActivitySnapshot{
		provider:    websocket_upstream_provider_fixture
		instance:    instance
		trace_id:    trace_id
		activity_id: activity_id
		event_type:  event_type
		message_id:  message_id
		target_type: target_type
		target:      req.target
		payload:     req.payload
		received_at: received_at
		recorded_at: received_at
	}
	if app.worker.worker_backend.sockets.len == 0 {
		app.websocket_upstream_record_activity(snapshot)
		return snapshot
	}
	outcome := app.kernel_dispatch_websocket_upstream_handled(app.kernel_websocket_upstream_dispatch_request(activity_id,
		websocket_upstream_provider_fixture, instance, trace_id, event_type, message_id,
		req.target, target_type, req.payload, received_at, req.metadata)) or {
		snapshot.worker_error = err.msg()
		snapshot.error_class = 'transport_error'
		app.websocket_upstream_record_activity(snapshot)
		return snapshot
	}
	resp := outcome.response
	if resp.error != '' {
		snapshot.worker_error = resp.error
		snapshot.error_class = resp.error_class
		app.websocket_upstream_record_activity(snapshot)
		return snapshot
	}
	snapshot.worker_handled = resp.handled
	snapshot.commands = outcome.command_snapshots
	snapshot.command_error = outcome.command_error
	app.websocket_upstream_record_activity(snapshot)
	return snapshot
}

// ── Activity & admin snapshots ──

fn (mut app App) websocket_upstream_record_activity(snapshot ws.UpstreamActivitySnapshot) {
	app.ws_hub.record_upstream_activity(snapshot)
}

fn (mut app App) admin_websocket_upstream_activities_snapshot(limit int, offset int, provider_filter string, instance_filter string) ws.UpstreamActivityListSnapshot {
	return app.ws_hub.upstream_activities_snapshot(limit, offset, provider_filter, instance_filter)
}

fn (mut app App) execute_websocket_upstream_commands(source_activity_id string, commands []transport.WorkerWebSocketUpstreamCommand) ([]executor.WebSocketUpstreamCommandActivity, string) {
	cmd_ctx := app.build_command_context()
	mut exec := command.CommandExecutor.new(cmd_ctx)
	ctx := DispatchContext{}
	return exec.execute(source_activity_id, ctx, commands)
}

// ── Provider routing ──

fn (mut app App) websocket_upstream_provider_enabled(provider string, instance string) bool {
	if provider == websocket_upstream_provider_fixture {
		return true
	}
	return app.provider_runtime_upstream_enabled(provider, instance)
}

fn (mut app App) websocket_upstream_snapshot(provider string, instance string) ?ws.UpstreamSnapshot {
	return match provider {
		websocket_upstream_provider_feishu {
			app.provider_runtime_upstream_snapshot('feishu', instance)
		}
		websocket_upstream_provider_fixture {
			return app.ws_hub.fixture_snapshot(instance)
		}
		websocket_upstream_provider_codex {
			app.provider_runtime_upstream_snapshot('codex', instance)
		}
		else {
			none
		}
	}
}

fn (mut app App) admin_websocket_upstreams_snapshot(details bool, limit int, offset int, provider_filter string, instance_filter string) ws.UpstreamRuntimeSnapshot {
	mut sessions := []ws.UpstreamSnapshot{}
	for name in app.provider_runtime_instances('feishu') {
		if provider_filter != '' && provider_filter != websocket_upstream_provider_feishu {
			break
		}
		if instance_filter != '' && instance_filter != name {
			continue
		}
		if snapshot := app.websocket_upstream_snapshot(websocket_upstream_provider_feishu, name) {
			sessions << snapshot
		}
	}
	for snapshot in app.provider_runtime_upstream_snapshots('codex') {
		if provider_filter != '' && provider_filter != websocket_upstream_provider_codex {
			break
		}
		if instance_filter != '' && instance_filter != snapshot.instance {
			continue
		}
		sessions << snapshot
	}
	for name in app.ws_hub.fixture_app_names() {
		if provider_filter != '' && provider_filter != websocket_upstream_provider_fixture {
			continue
		}
		if instance_filter != '' && instance_filter != name {
			continue
		}
		if snapshot := app.websocket_upstream_snapshot(websocket_upstream_provider_fixture, name) {
			sessions << snapshot
		}
	}
	total := sessions.len
	if offset >= sessions.len {
		return ws.UpstreamRuntimeSnapshot{
			active_count:   total
			returned_count: 0
			details:        details
			limit:          limit
			offset:         offset
			sessions:       []ws.UpstreamSnapshot{}
		}
	}
	end := if offset + limit < sessions.len { offset + limit } else { sessions.len }
	return ws.UpstreamRuntimeSnapshot{
		active_count:   total
		returned_count: end - offset
		details:        details
		limit:          limit
		offset:         offset
		sessions:       sessions[offset..end].clone()
	}
}

fn (mut app App) websocket_upstream_provider_pull_url(provider string, instance string) !string {
	if provider == websocket_upstream_provider_fixture {
		return error('unknown websocket upstream provider ${provider}')
	}
	return app.provider_runtime_pull_url(provider, instance)
}

fn (mut app App) websocket_upstream_provider_on_connected(provider string, instance string, ws_url string) {
	if provider == websocket_upstream_provider_fixture {
		return
	}
	app.provider_runtime_on_connected(provider, instance, ws_url)
}

fn (mut app App) websocket_upstream_provider_on_connecting(provider string, instance string) {
	if provider == websocket_upstream_provider_fixture {
		return
	}
	app.provider_runtime_on_connecting(provider, instance)
}

fn (mut app App) websocket_upstream_provider_on_disconnected(provider string, instance string, reason string) {
	app.emit('websocket_upstream.disconnected', {
		'provider': provider
		'instance': instance
		'reason':   reason
	})
	if provider == websocket_upstream_provider_fixture {
		return
	}
	app.provider_runtime_on_disconnected(provider, instance, reason)
}

fn (mut app App) websocket_upstream_provider_reconnect_delay_ms(provider string, instance string) int {
	if provider == websocket_upstream_provider_fixture {
		return 3000
	}
	return app.provider_runtime_reconnect_delay_ms(provider, instance)
}

fn (mut app App) websocket_upstream_provider_handle_message(provider string, instance string, mut ws_client websocket.Client, msg &websocket.Message) ! {
	if provider == websocket_upstream_provider_codex {
		mut payload_preview := ''
		if msg.opcode == .text_frame || msg.opcode == .binary_frame || msg.opcode == .continuation {
			raw := msg.payload.bytestr()
			payload_preview = if raw.len > 200 { raw[..200] + '...' } else { raw }
		}
		log.info('[codex][ws] 📨 opcode=${msg.opcode} payload_len=${msg.payload.len} instance=${instance} preview=${payload_preview}')
	}
	match provider {
		websocket_upstream_provider_feishu {
			app.feishu_provider_handle_binary_message(instance, mut ws_client, msg)!
		}
		websocket_upstream_provider_codex {
			if msg.opcode == .text_frame {
				app.codex_provider_handle_text_message(instance, msg.payload.bytestr())
			} else {
				log.warn('[codex][ws] ignored non-text opcode=${msg.opcode} payload_len=${msg.payload.len} instance=${instance}')
			}
		}
		else {}
	}
}

// ── Send / Update ──

fn (mut app App) websocket_upstream_provider_send(provider string, req WebSocketUpstreamSendRequest) !ws.UpstreamSendResult {
	return match provider {
		websocket_upstream_provider_feishu {
			if app.feishu_card_bridge_enabled() {
				return app.feishu_card_bridge_proxy_send(req)
			}
			result := app.feishu_runtime_send_message(feishu.SendMessageRequest{
				app:             req.instance
				receive_id_type: req.target_type
				receive_id:      req.target
				msg_type:        req.message_type
				content:         req.content
				content_fields:  req.content_fields.clone()
				text:            req.text
				uuid:            req.uuid
			})!
			return ws.UpstreamSendResult{
				ok:         result.ok
				provider:   provider
				instance:   app.feishu.resolve_app_name(req.instance)!
				message_id: result.message_id
				error:      result.error
			}
		}
		websocket_upstream_provider_fixture {
			return app.ws_hub.fixture_send(req.instance)
		}
		websocket_upstream_provider_codex {
			return app.codex_provider_send(req)
		}
		else {
			return error('unknown websocket upstream provider ${provider}')
		}
	}
}

fn (mut app App) websocket_upstream_provider_update(provider string, req WebSocketUpstreamSendRequest) !ws.UpstreamUpdateResult {
	return match provider {
		websocket_upstream_provider_feishu {
			if app.feishu_card_bridge_enabled() {
				return app.feishu_card_bridge_proxy_update(req)
			}
			result := app.feishu_runtime_update_message(feishu.UpdateMessageRequest{
				app:             req.instance
				message_id:      req.target
				message_id_type: req.target_type
				msg_type:        req.message_type
				content:         req.content
				content_fields:  req.content_fields.clone()
				text:            req.text
				uuid:            req.uuid
			})!
			return ws.UpstreamUpdateResult{
				ok:         result.ok
				provider:   provider
				instance:   app.feishu.resolve_app_name(req.instance)!
				message_id: result.message_id
				error:      result.error
			}
		}
		websocket_upstream_provider_fixture {
			return app.ws_hub.fixture_update_msg(req.instance, req.target)
		}
		websocket_upstream_provider_codex {
			return app.codex_provider_update(req)
		}
		else {
			return error('unknown websocket upstream provider ${provider}')
		}
	}
}

fn (mut app App) websocket_upstream_send(req WebSocketUpstreamSendRequest) !ws.UpstreamSendResult {
	provider := if req.provider.trim_space() == '' {
		websocket_upstream_provider_feishu
	} else {
		req.provider.trim_space()
	}
	normalized := WebSocketUpstreamSendRequest{
		provider:       provider
		instance:       if req.instance.trim_space() != '' {
			req.instance.trim_space()
		} else {
			req.app.trim_space()
		}
		app:            req.app
		target_type:    req.target_type
		target:         req.target
		message_type:   req.message_type
		content:        req.content
		content_fields: req.content_fields.clone()
		text:           req.text
		uuid:           req.uuid
		metadata:       req.metadata.clone()
	}
	return app.websocket_upstream_provider_send(provider, normalized)
}

fn (mut app App) websocket_upstream_update(req WebSocketUpstreamSendRequest) !ws.UpstreamUpdateResult {
	provider := if req.provider.trim_space() == '' {
		websocket_upstream_provider_feishu
	} else {
		req.provider.trim_space()
	}
	normalized := WebSocketUpstreamSendRequest{
		provider:       provider
		instance:       if req.instance.trim_space() != '' {
			req.instance.trim_space()
		} else {
			req.app.trim_space()
		}
		app:            req.app
		target_type:    req.target_type
		target:         req.target
		message_type:   req.message_type
		content:        req.content
		content_fields: req.content_fields.clone()
		text:           req.text
		uuid:           req.uuid
		metadata:       req.metadata.clone()
	}
	return app.websocket_upstream_provider_update(provider, normalized)
}

// ── Events snapshot ──

fn (mut app App) admin_websocket_upstream_events_snapshot(limit int, offset int, provider_filter string, instance_filter string) ws.UpstreamEventListSnapshot {
	mut events := []ws.UpstreamEventSnapshot{}
	if provider_filter == '' || provider_filter == websocket_upstream_provider_feishu {
		events << app.provider_runtime_upstream_events('feishu', instance_filter)
	}
	if provider_filter == '' || provider_filter == websocket_upstream_provider_fixture {
		for name in app.ws_hub.fixture_app_names() {
			if instance_filter != '' && name != instance_filter {
				continue
			}
			runtime := app.ws_hub.fixture_ensure(name)
			for event in runtime.recent_events {
				events << event
			}
		}
	}
	events.sort(a.received_at > b.received_at)
	if offset >= events.len {
		return ws.UpstreamEventListSnapshot{
			returned_count: 0
			limit:          limit
			offset:         offset
			events:         []ws.UpstreamEventSnapshot{}
		}
	}
	end := if offset + limit < events.len { offset + limit } else { events.len }
	return ws.UpstreamEventListSnapshot{
		returned_count: end - offset
		limit:          limit
		offset:         offset
		events:         events[offset..end].clone()
	}
}

// ── Provider lifecycle ──

fn (mut app App) websocket_upstream_mark_started(provider string, instance string) bool {
	key := ws.UpstreamRuntimeContext.started_key(provider, instance)
	if key == '/' || provider.trim_space() == '' || instance.trim_space() == '' {
		return false
	}
	app.ws_hub.upstream_mu.@lock()
	defer {
		app.ws_hub.upstream_mu.unlock()
	}
	if key in app.ws_hub.upstream_started {
		return false
	}
	app.ws_hub.upstream_started[key] = true
	return true
}

fn (mut app App) ensure_websocket_upstream_provider_running(provider string, instance string) bool {
	resolved_provider := provider.trim_space()
	mut resolved_instance := instance.trim_space()
	if resolved_provider == '' {
		return false
	}
	if !app.ws_hub.auto_start_dynamic_upstreams {
		return false
	}
	if resolved_instance == '' {
		resolved_instance = app.provider_runtime_default_instance(resolved_provider)
	}
	if resolved_instance == '' {
		return false
	}
	if !app.provider_runtime_upstream_enabled(resolved_provider, resolved_instance) {
		return false
	}
	if !app.websocket_upstream_mark_started(resolved_provider, resolved_instance) {
		return false
	}
	go run_websocket_upstream_provider(mut app, resolved_provider, resolved_instance)
	return true
}

fn run_websocket_upstream_provider(mut app App, provider string, instance string) {
	rt := app.build_websocket_upstream_runtime_context()
	ws.upstream_run_provider(rt, provider, instance)
}

// ── Admin HTTP endpoints (App) ──

@['/admin/runtime/upstreams/websocket'; get]
pub fn (mut app App) admin_runtime_websocket_upstreams(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime/upstreams/websocket' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	instance_filter := (ctx.query['instance'] or { '' }).trim_space()
	body := json.encode(app.admin_websocket_upstreams_snapshot(details, limit, offset,
		provider_filter, instance_filter))
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/upstreams/websocket'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}

@['/admin/runtime/upstreams/websocket/events'; get]
pub fn (mut app App) admin_runtime_websocket_upstream_events(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime/upstreams/websocket/events' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	instance_filter := (ctx.query['instance'] or { '' }).trim_space()
	body := json.encode(app.admin_websocket_upstream_events_snapshot(limit, offset,
		provider_filter, instance_filter))
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/upstreams/websocket/events'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}

@['/admin/runtime/upstreams/websocket/activities'; get]
pub fn (mut app App) admin_runtime_websocket_upstream_activities(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' {
		'/admin/runtime/upstreams/websocket/activities'
	} else {
		ctx.req.url
	}
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	instance_filter := (ctx.query['instance'] or { '' }).trim_space()
	body := json.encode(app.admin_websocket_upstream_activities_snapshot(limit, offset,
		provider_filter, instance_filter))
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/upstreams/websocket/activities'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}

@['/admin/runtime/upstreams/websocket/fixture/emit'; post]
pub fn (mut app App) admin_runtime_websocket_upstream_fixture_emit(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' {
		'/admin/runtime/upstreams/websocket/fixture/emit'
	} else {
		ctx.req.url
	}
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	req := json.decode(ws.UpstreamFixtureEmitRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'invalid_json'
		}))
	}
	snapshot := app.fixture_websocket_emit(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}))
	}
	app.emit('http.request', {
		'method':     'POST'
		'path':       '/admin/runtime/upstreams/websocket/fixture/emit'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(json.encode(snapshot))
}

@['/admin/runtime/upstreams/websocket/send'; post]
pub fn (mut app App) admin_runtime_websocket_upstream_send(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime/upstreams/websocket/send' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	req := json.decode(WebSocketUpstreamSendRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(ws.UpstreamSendResult{
			ok:    false
			error: 'invalid_json'
		}))
	}
	result := app.websocket_upstream_send(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(ws.UpstreamSendResult{
			ok:    false
			error: err.msg()
		}))
	}
	app.emit('http.request', {
		'method':     'POST'
		'path':       '/admin/runtime/upstreams/websocket/send'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(json.encode(result))
}

@['/gateway/upstreams/websocket/send'; post]
pub fn (mut app App) gateway_websocket_upstream_send(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/gateway/upstreams/websocket/send' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.api_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	req := json.decode(WebSocketUpstreamSendRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(ws.UpstreamSendResult{
			ok:    false
			error: 'invalid_json'
		}))
	}
	result := app.websocket_upstream_send(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(ws.UpstreamSendResult{
			ok:    false
			error: err.msg()
		}))
	}
	app.emit('http.request', {
		'method':     'POST'
		'path':       '/gateway/upstreams/websocket/send'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'gateway'
	})
	return ctx.text(json.encode(result))
}

// ── Admin HTTP endpoints (AdminApp) ──

@['/admin/runtime/upstreams/websocket'; get]
pub fn (mut app AdminApp) admin_runtime_websocket_upstreams(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/upstreams/websocket' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	instance_filter := (ctx.query['instance'] or { '' }).trim_space()
	body := json.encode(app.shared.admin_websocket_upstreams_snapshot(details, limit, offset,
		provider_filter, instance_filter))
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/upstreams/websocket'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/runtime/upstreams/websocket/events'; get]
pub fn (mut app AdminApp) admin_runtime_websocket_upstream_events(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/upstreams/websocket/events' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	instance_filter := (ctx.query['instance'] or { '' }).trim_space()
	body := json.encode(app.shared.admin_websocket_upstream_events_snapshot(limit, offset,
		provider_filter, instance_filter))
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/upstreams/websocket/events'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/runtime/upstreams/websocket/activities'; get]
pub fn (mut app AdminApp) admin_runtime_websocket_upstream_activities(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' {
		'/admin/runtime/upstreams/websocket/activities'
	} else {
		ctx.req.url
	}
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	instance_filter := (ctx.query['instance'] or { '' }).trim_space()
	body := json.encode(app.shared.admin_websocket_upstream_activities_snapshot(limit, offset,
		provider_filter, instance_filter))
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/upstreams/websocket/activities'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/runtime/upstreams/websocket/fixture/emit'; post]
pub fn (mut app AdminApp) admin_runtime_websocket_upstream_fixture_emit(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' {
		'/admin/runtime/upstreams/websocket/fixture/emit'
	} else {
		ctx.req.url
	}
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	req := json.decode(ws.UpstreamFixtureEmitRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'invalid_json'
		}))
	}
	snapshot := app.shared.fixture_websocket_emit(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}))
	}
	app.shared.emit('http.request', {
		'method':     'POST'
		'path':       '/admin/runtime/upstreams/websocket/fixture/emit'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(json.encode(snapshot))
}

@['/admin/runtime/upstreams/websocket/send'; post]
pub fn (mut app AdminApp) admin_runtime_websocket_upstream_send(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/upstreams/websocket/send' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	req := json.decode(WebSocketUpstreamSendRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'invalid_json'
		}))
	}
	result := app.shared.websocket_upstream_send(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(ws.UpstreamSendResult{
			ok:    false
			error: err.msg()
		}))
	}
	app.shared.emit('http.request', {
		'method':     'POST'
		'path':       '/admin/runtime/upstreams/websocket/send'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(json.encode(result))
}
