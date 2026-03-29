module main

import json
import net.http
import net.websocket
import time
import veb

const websocket_upstream_provider_feishu = 'feishu'
const websocket_upstream_provider_fixture = 'fixture'

@[heap]
struct WebSocketUpstreamRef {
mut:
	app      &App = unsafe { nil }
	provider string
	instance string
}

struct WebSocketUpstreamSnapshot {
	provider                string
	instance                string
	enabled                 bool
	configured              bool
	connected               bool
	url                     string
	last_connect_at_unix    i64
	last_disconnect_at_unix i64
	last_error              string
	connect_attempts        i64
	connect_successes       i64
	received_frames         i64
}

struct AdminWebSocketUpstreamRuntimeSnapshot {
	active_count   int
	returned_count int
	details        bool
	limit          int
	offset         int
	sessions       []WebSocketUpstreamSnapshot
}

pub struct WebSocketUpstreamSendRequest {
pub mut:
	provider       string
	instance       string
	app            string @[json: 'app']
	target_type    string @[json: 'target_type']
	target         string
	message_type   string @[json: 'message_type']
	content        string
	content_fields map[string]string @[json: 'content_fields']
	text           string
	uuid           string
	method         string
	params         string
	metadata       map[string]string
}

struct WebSocketUpstreamSendResult {
	ok         bool
	provider   string
	instance   string
	message_id string @[json: 'message_id']
	error      string
}

struct WebSocketUpstreamUpdateResult {
	ok         bool
	provider   string
	instance   string
	message_id string @[json: 'message_id']
	error      string
}

struct WebSocketUpstreamEventSnapshot {
	provider    string
	instance    string
	event_type  string
	message_id  string
	target      string
	target_type string @[json: 'target_type']
	trace_id    string
	received_at i64
	payload     string
	metadata    map[string]string
}

struct AdminWebSocketUpstreamEventSnapshot {
	returned_count int
	limit          int
	offset         int
	events         []WebSocketUpstreamEventSnapshot
}

struct FixtureWebSocketUpstreamRuntime {
mut:
	name                    string
	connected               bool
	last_connect_at_unix    i64
	last_disconnect_at_unix i64
	last_error              string
	connect_attempts        i64
	connect_successes       i64
	received_frames         i64
	messages_sent           i64
	send_errors             i64
	recent_events           []WebSocketUpstreamEventSnapshot
}

struct WebSocketUpstreamFixtureEmitRequest {
	provider    string
	instance    string
	trace_id    string @[json: 'trace_id']
	event_type  string @[json: 'event_type']
	message_id  string @[json: 'message_id']
	target_type string @[json: 'target_type']
	target      string
	payload     string
	metadata    map[string]string
}

fn (mut app App) fixture_websocket_runtime_ensure(name string) FixtureWebSocketUpstreamRuntime {
	app.upstream_mu.@lock()
	defer {
		app.upstream_mu.unlock()
	}
	if name in app.fixture_websocket_runtime {
		return app.fixture_websocket_runtime[name]
	}
	runtime := FixtureWebSocketUpstreamRuntime{
		name:                 name
		connected:            true
		last_connect_at_unix: time.now().unix()
		connect_attempts:     1
		connect_successes:    1
	}
	app.fixture_websocket_runtime[name] = runtime
	return runtime
}

fn (mut app App) fixture_websocket_runtime_update(name string, runtime FixtureWebSocketUpstreamRuntime) {
	app.upstream_mu.@lock()
	defer {
		app.upstream_mu.unlock()
	}
	app.fixture_websocket_runtime[name] = runtime
}

fn (mut app App) fixture_websocket_app_names() []string {
	app.upstream_mu.@lock()
	defer {
		app.upstream_mu.unlock()
	}
	mut names := app.fixture_websocket_runtime.keys()
	names.sort()
	return names
}

fn (mut app App) fixture_websocket_snapshot(name string) WebSocketUpstreamSnapshot {
	runtime := app.fixture_websocket_runtime_ensure(name)
	return WebSocketUpstreamSnapshot{
		provider:                websocket_upstream_provider_fixture
		instance:                runtime.name
		enabled:                 true
		configured:              true
		connected:               runtime.connected
		url:                     'fixture://${runtime.name}'
		last_connect_at_unix:    runtime.last_connect_at_unix
		last_disconnect_at_unix: runtime.last_disconnect_at_unix
		last_error:              runtime.last_error
		connect_attempts:        runtime.connect_attempts
		connect_successes:       runtime.connect_successes
		received_frames:         runtime.received_frames
	}
}

fn (mut app App) fixture_websocket_push_event(instance string, event WebSocketUpstreamEventSnapshot) {
	mut runtime := app.fixture_websocket_runtime_ensure(instance)
	mut events := runtime.recent_events.clone()
	events << event
	limit := if app.feishu_recent_event_limit > 0 { app.feishu_recent_event_limit } else { 20 }
	if events.len > limit {
		events = events[events.len - limit..].clone()
	}
	runtime.received_frames++
	runtime.recent_events = events
	app.fixture_websocket_runtime_update(instance, runtime)
}

fn (mut app App) fixture_websocket_note_send(instance string, ok bool) {
	mut runtime := app.fixture_websocket_runtime_ensure(instance)
	if ok {
		runtime.messages_sent++
	} else {
		runtime.send_errors++
	}
	app.fixture_websocket_runtime_update(instance, runtime)
}

fn (mut app App) fixture_websocket_send(req WebSocketUpstreamSendRequest) !WebSocketUpstreamSendResult {
	instance := if req.instance.trim_space() == '' { 'main' } else { req.instance.trim_space() }
	app.fixture_websocket_note_send(instance, true)
	return WebSocketUpstreamSendResult{
		ok:         true
		provider:   websocket_upstream_provider_fixture
		instance:   instance
		message_id: 'fixture-msg-${time.now().unix_micro()}'
	}
}

fn (mut app App) fixture_websocket_update(req WebSocketUpstreamSendRequest) !WebSocketUpstreamUpdateResult {
	instance := if req.instance.trim_space() == '' { 'main' } else { req.instance.trim_space() }
	target := req.target.trim_space()
	if target == '' {
		return error('missing fixture update target')
	}
	app.fixture_websocket_note_send(instance, true)
	return WebSocketUpstreamUpdateResult{
		ok:         true
		provider:   websocket_upstream_provider_fixture
		instance:   instance
		message_id: target
	}
}

fn (mut app App) fixture_websocket_emit(req WebSocketUpstreamFixtureEmitRequest) !WebSocketUpstreamActivitySnapshot {
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
	event := WebSocketUpstreamEventSnapshot{
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
	app.fixture_websocket_push_event(instance, event)
	mut snapshot := WebSocketUpstreamActivitySnapshot{
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
	if app.worker_backend.sockets.len == 0 {
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

struct WebSocketUpstreamCommandActivity {
mut:
	event          string
	provider       string
	instance       string
	target_type    string @[json: 'target_type']
	target         string
	message_type   string @[json: 'message_type']
	content        string
	content_fields map[string]string @[json: 'content_fields']
	text           string
	uuid           string
	metadata       map[string]string

	type_                string @[json: 'type']
	stream_id            string @[json: 'stream_id']
	session_key          string @[json: 'session_key']
	task_type            string @[json: 'task_type']
	prompt               string
	source_activity_id   string @[json: 'source_activity_id']
	source_command_index int    @[json: 'source_command_index']
	status               string
	error                string
	message_id           string @[json: 'message_id']
	executed_at          i64    @[json: 'executed_at']
}

struct WebSocketUpstreamActivitySnapshot {
mut:
	provider       string
	instance       string
	trace_id       string @[json: 'trace_id']
	activity_id    string @[json: 'activity_id']
	event_type     string @[json: 'event_type']
	message_id     string @[json: 'message_id']
	target_type    string @[json: 'target_type']
	target         string
	payload        string
	received_at    i64    @[json: 'received_at']
	worker_handled bool   @[json: 'worker_handled']
	worker_error   string @[json: 'worker_error']
	error_class    string @[json: 'error_class']
	command_error  string @[json: 'command_error']
	commands       []WebSocketUpstreamCommandActivity
	recorded_at    i64 @[json: 'recorded_at']
}

struct AdminWebSocketUpstreamActivitySnapshot {
	returned_count int
	limit          int
	offset         int
	activities     []WebSocketUpstreamActivitySnapshot
}

fn (mut app App) websocket_upstream_record_activity(snapshot WebSocketUpstreamActivitySnapshot) {
	app.upstream_mu.@lock()
	defer {
		app.upstream_mu.unlock()
	}
	limit := if app.websocket_upstream_recent_dispatch_limit > 0 {
		app.websocket_upstream_recent_dispatch_limit
	} else {
		50
	}
	app.websocket_upstream_recent_activities << snapshot
	if app.websocket_upstream_recent_activities.len > limit {
		start := app.websocket_upstream_recent_activities.len - limit
		app.websocket_upstream_recent_activities = app.websocket_upstream_recent_activities[start..].clone()
	}
}

fn (mut app App) admin_websocket_upstream_activities_snapshot(limit int, offset int, provider_filter string, instance_filter string) AdminWebSocketUpstreamActivitySnapshot {
	app.upstream_mu.@lock()
	defer {
		app.upstream_mu.unlock()
	}
	mut activities := []WebSocketUpstreamActivitySnapshot{}
	for entry in app.websocket_upstream_recent_activities {
		if provider_filter != '' && entry.provider != provider_filter {
			continue
		}
		if instance_filter != '' && entry.instance != instance_filter {
			continue
		}
		activities << entry
	}
	activities.sort(a.received_at > b.received_at)
	if offset >= activities.len {
		return AdminWebSocketUpstreamActivitySnapshot{
			returned_count: 0
			limit:          limit
			offset:         offset
			activities:     []WebSocketUpstreamActivitySnapshot{}
		}
	}
	end := if offset + limit < activities.len { offset + limit } else { activities.len }
	return AdminWebSocketUpstreamActivitySnapshot{
		returned_count: end - offset
		limit:          limit
		offset:         offset
		activities:     activities[offset..end].clone()
	}
}

fn (mut app App) execute_websocket_upstream_commands(source_activity_id string, commands []WorkerWebSocketUpstreamCommand) ([]WebSocketUpstreamCommandActivity, string) {
	mut exec := CommandExecutor.new(mut app)
	ctx := DispatchContext{}
	return exec.execute(source_activity_id, ctx, commands)
}

fn (app &App) websocket_upstream_provider_enabled(provider string, instance string) bool {
	if provider == websocket_upstream_provider_fixture {
		return true
	}
	mut app_mut := unsafe { &App(app) }
	return app_mut.provider_runtime_upstream_enabled(provider, instance)
}

fn (mut app App) websocket_upstream_snapshot(provider string, instance string) ?WebSocketUpstreamSnapshot {
	return match provider {
		websocket_upstream_provider_feishu {
			app.provider_runtime_upstream_snapshot('feishu', instance)
		}
		websocket_upstream_provider_fixture {
			return app.fixture_websocket_snapshot(instance)
		}
		websocket_upstream_provider_codex {
			app.provider_runtime_upstream_snapshot('codex', instance)
		}
		else {
			none
		}
	}
}

fn (mut app App) admin_websocket_upstreams_snapshot(details bool, limit int, offset int, provider_filter string, instance_filter string) AdminWebSocketUpstreamRuntimeSnapshot {
	mut sessions := []WebSocketUpstreamSnapshot{}
	for name in app.provider_runtime_instances('feishu') {
		if provider_filter != '' && provider_filter != websocket_upstream_provider_feishu {
			break
		}
		if instance_filter != '' && instance_filter != name {
			continue
		}
		if snapshot := app.websocket_upstream_snapshot(websocket_upstream_provider_feishu,
			name)
		{
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
	for name in app.fixture_websocket_app_names() {
		if provider_filter != '' && provider_filter != websocket_upstream_provider_fixture {
			continue
		}
		if instance_filter != '' && instance_filter != name {
			continue
		}
		if snapshot := app.websocket_upstream_snapshot(websocket_upstream_provider_fixture,
			name)
		{
			sessions << snapshot
		}
	}
	total := sessions.len
	if offset >= sessions.len {
		return AdminWebSocketUpstreamRuntimeSnapshot{
			active_count:   total
			returned_count: 0
			details:        details
			limit:          limit
			offset:         offset
			sessions:       []WebSocketUpstreamSnapshot{}
		}
	}
	end := if offset + limit < sessions.len { offset + limit } else { sessions.len }
	return AdminWebSocketUpstreamRuntimeSnapshot{
		active_count:   total
		returned_count: end - offset
		details:        details
		limit:          limit
		offset:         offset
		sessions:       sessions[offset..end].clone()
	}
}

fn websocket_upstream_provider_pull_url(mut app App, provider string, instance string) !string {
	if provider == websocket_upstream_provider_fixture {
		return error('unknown websocket upstream provider ${provider}')
	}
	return app.provider_runtime_pull_url(provider, instance)
}

fn websocket_upstream_provider_on_connected(mut app App, provider string, instance string, ws_url string) {
	if provider == websocket_upstream_provider_fixture {
		return
	}
	app.provider_runtime_on_connected(provider, instance, ws_url)
}

fn websocket_upstream_provider_on_connecting(mut app App, provider string, instance string) {
	if provider == websocket_upstream_provider_fixture {
		return
	}
	app.provider_runtime_on_connecting(provider, instance)
}

fn websocket_upstream_provider_on_disconnected(mut app App, provider string, instance string, reason string) {
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

fn websocket_upstream_provider_reconnect_delay_ms(app &App, provider string, instance string) int {
	mut app_mut := unsafe { &App(app) }
	if provider == websocket_upstream_provider_fixture {
		return 3000
	}
	return app_mut.provider_runtime_reconnect_delay_ms(provider, instance)
}

fn websocket_upstream_provider_handle_message(mut app App, provider string, instance string, mut ws websocket.Client, msg &websocket.Message) ! {
	match provider {
		websocket_upstream_provider_feishu {
			app.feishu_provider_handle_binary_message(instance, mut ws, msg)!
		}
		websocket_upstream_provider_codex {
			if msg.opcode == .text_frame {
				app.codex_provider_handle_text_message(instance, msg.payload.bytestr())
			}
		}
		else {}
	}
}

fn websocket_upstream_provider_send(mut app App, provider string, req WebSocketUpstreamSendRequest) !WebSocketUpstreamSendResult {
	return match provider {
		websocket_upstream_provider_feishu {
			result := app.feishu_runtime_send_message(FeishuRuntimeSendMessageRequest{
				app:             req.instance
				receive_id_type: req.target_type
				receive_id:      req.target
				msg_type:        req.message_type
				content:         req.content
				content_fields:  req.content_fields.clone()
				text:            req.text
				uuid:            req.uuid
			})!
			return WebSocketUpstreamSendResult{
				ok:         result.ok
				provider:   provider
				instance:   app.feishu_runtime_resolve_app_name(req.instance)!
				message_id: result.message_id
				error:      result.error
			}
		}
		websocket_upstream_provider_fixture {
			return app.fixture_websocket_send(req)
		}
		websocket_upstream_provider_codex {
			return app.codex_provider_send(req)
		}
		else {
			return error('unknown websocket upstream provider ${provider}')
		}
	}
}

fn websocket_upstream_provider_update(mut app App, provider string, req WebSocketUpstreamSendRequest) !WebSocketUpstreamUpdateResult {
	return match provider {
		websocket_upstream_provider_feishu {
			result := app.feishu_runtime_update_message(FeishuRuntimeUpdateMessageRequest{
				app:             req.instance
				message_id:      req.target
				message_id_type: req.target_type
				msg_type:        req.message_type
				content:         req.content
				content_fields:  req.content_fields.clone()
				text:            req.text
				uuid:            req.uuid
			})!
			return WebSocketUpstreamUpdateResult{
				ok:         result.ok
				provider:   provider
				instance:   app.feishu_runtime_resolve_app_name(req.instance)!
				message_id: result.message_id
				error:      result.error
			}
		}
		websocket_upstream_provider_fixture {
			return app.fixture_websocket_update(req)
		}
		websocket_upstream_provider_codex {
			return app.codex_provider_update(req)
		}
		else {
			return error('unknown websocket upstream provider ${provider}')
		}
	}
}

fn (mut app App) websocket_upstream_send(req WebSocketUpstreamSendRequest) !WebSocketUpstreamSendResult {
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
	return websocket_upstream_provider_send(mut app, provider, normalized)
}

fn (mut app App) websocket_upstream_update(req WebSocketUpstreamSendRequest) !WebSocketUpstreamUpdateResult {
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
	return websocket_upstream_provider_update(mut app, provider, normalized)
}

fn (mut app App) admin_websocket_upstream_events_snapshot(limit int, offset int, provider_filter string, instance_filter string) AdminWebSocketUpstreamEventSnapshot {
	mut events := []WebSocketUpstreamEventSnapshot{}
	if provider_filter == '' || provider_filter == websocket_upstream_provider_feishu {
		events << app.provider_runtime_upstream_events('feishu', instance_filter)
	}
	if provider_filter == '' || provider_filter == websocket_upstream_provider_fixture {
		for name in app.fixture_websocket_app_names() {
			if instance_filter != '' && name != instance_filter {
				continue
			}
			runtime := app.fixture_websocket_runtime_ensure(name)
			for event in runtime.recent_events {
				events << event
			}
		}
	}
	events.sort(a.received_at > b.received_at)
	if offset >= events.len {
		return AdminWebSocketUpstreamEventSnapshot{
			returned_count: 0
			limit:          limit
			offset:         offset
			events:         []WebSocketUpstreamEventSnapshot{}
		}
	}
	end := if offset + limit < events.len { offset + limit } else { events.len }
	return AdminWebSocketUpstreamEventSnapshot{
		returned_count: end - offset
		limit:          limit
		offset:         offset
		events:         events[offset..end].clone()
	}
}

fn websocket_upstream_message_cb(mut ws websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &WebSocketUpstreamRef(ref) }
	if isnil(state.app) {
		return
	}
	websocket_upstream_provider_handle_message(mut state.app, state.provider, state.instance, mut
		ws, msg)!
}

fn websocket_upstream_error_cb(mut _ws websocket.Client, err string, ref voidptr) ! {
	mut state := unsafe { &WebSocketUpstreamRef(ref) }
	if isnil(state.app) {
		return
	}
	websocket_upstream_provider_on_disconnected(mut state.app, state.provider, state.instance,
		err)
}

fn websocket_upstream_close_cb(mut _ws websocket.Client, code int, reason string, ref voidptr) ! {
	mut state := unsafe { &WebSocketUpstreamRef(ref) }
	if isnil(state.app) {
		return
	}
	websocket_upstream_provider_on_disconnected(mut state.app, state.provider, state.instance,
		'close:${code}:${reason}')
}

fn websocket_upstream_started_key(provider string, instance string) string {
	return '${provider.trim_space()}/${instance.trim_space()}'
}

fn (mut app App) websocket_upstream_mark_started(provider string, instance string) bool {
	key := websocket_upstream_started_key(provider, instance)
	if key == '/' || provider.trim_space() == '' || instance.trim_space() == '' {
		return false
	}
	app.upstream_mu.@lock()
	defer {
		app.upstream_mu.unlock()
	}
	if key in app.websocket_upstream_started {
		return false
	}
	app.websocket_upstream_started[key] = true
	return true
}

fn (mut app App) ensure_websocket_upstream_provider_running(provider string, instance string) bool {
	resolved_provider := provider.trim_space()
	mut resolved_instance := instance.trim_space()
	if resolved_provider == '' {
		return false
	}
	if !app.auto_start_dynamic_upstreams {
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
	if !app.websocket_upstream_provider_enabled(provider, instance) {
		return
	}
	reconnect_delay := websocket_upstream_provider_reconnect_delay_ms(app, provider, instance)
	mut ref := &WebSocketUpstreamRef{
		app:      unsafe { &app }
		provider: provider
		instance: instance
	}
	for {
		websocket_upstream_provider_on_connecting(mut app, provider, instance)
		ws_url := websocket_upstream_provider_pull_url(mut app, provider, instance) or {
			websocket_upstream_provider_on_disconnected(mut app, provider, instance, 'endpoint:${err}')
			time.sleep(reconnect_delay * time.millisecond)
			continue
		}
		mut client := websocket.new_client(ws_url,
			read_timeout:  60 * time.second
			write_timeout: 60 * time.second
		) or {
			websocket_upstream_provider_on_disconnected(mut app, provider, instance, 'client:${err}')
			time.sleep(reconnect_delay * time.millisecond)
			continue
		}
		client.on_message_ref(websocket_upstream_message_cb, ref)
		client.on_error_ref(websocket_upstream_error_cb, ref)
		client.on_close_ref(websocket_upstream_close_cb, ref)
		client.connect() or {
			websocket_upstream_provider_on_disconnected(mut app, provider, instance, 'connect:${err}')
			time.sleep(reconnect_delay * time.millisecond)
			continue
		}
		websocket_upstream_provider_on_connected(mut app, provider, instance, ws_url)
		app.emit('websocket_upstream.connected', {
			'provider': provider
			'instance': instance
			'url':      ws_url
		})
		if provider == websocket_upstream_provider_feishu {
			mut feishu_app_ref := unsafe { &app }
			go feishu_runtime_ping_loop(mut feishu_app_ref, instance, ws_url, mut client)
		} else if provider == websocket_upstream_provider_codex {
			mut codex_app_ref := unsafe { &app }
			go codex_app_ref.codex_post_connect_handshake(instance, mut client)
			go codex_ping_loop(mut client)
		}
		client.listen() or {
			websocket_upstream_provider_on_disconnected(mut app, provider, instance, 'listen:${err}')
		}
		time.sleep(reconnect_delay * time.millisecond)
	}
}

@['/admin/runtime/upstreams/websocket'; get]
pub fn (mut app App) admin_runtime_websocket_upstreams(mut ctx Context) veb.Result {
	if !app.admin_on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime/upstreams/websocket' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	details := admin_query_boolish(ctx.query['details'] or { 'false' })
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
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
	if !app.admin_on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime/upstreams/websocket/events' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	instance_filter := (ctx.query['instance'] or { '' }).trim_space()
	body := json.encode(app.admin_websocket_upstream_events_snapshot(limit, offset, provider_filter,
		instance_filter))
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
	if !app.admin_on_data_plane {
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
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
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
	if !app.admin_on_data_plane {
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
	req := json.decode(WebSocketUpstreamFixtureEmitRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'invalid_json'
		}))
	}
	snapshot := app.fixture_websocket_emit(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(AdminErrorResponse{
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
	if !app.admin_on_data_plane {
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
		return ctx.text(json.encode(WebSocketUpstreamSendResult{
			ok:    false
			error: 'invalid_json'
		}))
	}
	result := app.websocket_upstream_send(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(WebSocketUpstreamSendResult{
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
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	req := json.decode(WebSocketUpstreamSendRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(WebSocketUpstreamSendResult{
			ok:    false
			error: 'invalid_json'
		}))
	}
	result := app.websocket_upstream_send(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(WebSocketUpstreamSendResult{
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

@['/admin/runtime/upstreams/websocket'; get]
pub fn (mut app AdminApp) admin_runtime_websocket_upstreams(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/upstreams/websocket' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	details := admin_query_boolish(ctx.query['details'] or { 'false' })
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	instance_filter := (ctx.query['instance'] or { '' }).trim_space()
	body := json.encode(app.shared.admin_websocket_upstreams_snapshot(details, limit,
		offset, provider_filter, instance_filter))
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
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
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
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	instance_filter := (ctx.query['instance'] or { '' }).trim_space()
	body := json.encode(app.shared.admin_websocket_upstream_activities_snapshot(limit,
		offset, provider_filter, instance_filter))
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
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	req := json.decode(WebSocketUpstreamFixtureEmitRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'invalid_json'
		}))
	}
	snapshot := app.shared.fixture_websocket_emit(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(AdminErrorResponse{
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
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	req := json.decode(WebSocketUpstreamSendRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'invalid_json'
		}))
	}
	result := app.shared.websocket_upstream_send(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(WebSocketUpstreamSendResult{
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
