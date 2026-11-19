module host

import json2 as json
import app_bundle
import net.http
import net.urllib
import time
import application_logs

// A registration identifies a vhttpd configuration/process, never an application.
// Applications use the same plan projection offline and through /admin/apps.
pub struct RuntimeApplication {
pub:
	identity app_bundle.ApplicationIdentity
 identity_error string
 id        string
	label     string
	status    string
	listeners []ApplicationListener
	engines   []ApplicationItem
	pipelines []ApplicationPipeline
	resources []ApplicationItem
	relays    []ApplicationItem
}

pub struct ApplicationListener {
pub:
	id       string
	protocol string
	host     string
	port     int
	tls      bool
	control  bool
}

pub struct ApplicationItem {
pub:
	id   string
	kind string
}

pub struct ApplicationPipeline {
pub:
	id        string
	ingress   string
	engine    string
	egress    string
	resources []string
}

struct WorkspaceHttpSamples {
	requests []WorkspaceHttpSample
}

struct WorkspaceHttpSample {
	request WorkspaceHttpRequest
}

struct WorkspaceHttpRequest {
	observation_id string
	pipeline_id    string
	method         string
	status         int
	duration_ms    i64
	at_unix        i64
}

struct ApplicationsResponse {
	apps []RuntimeApplication
}

pub struct RuntimeEvent {
pub:
	id      string
	kind    string @[json: 'type']
	at_unix i64
	fields  map[string]string
}

pub struct RuntimeWorkspace {
pub:
	inventory_known bool
	from_configuration bool
	application_logs_unsupported bool
	application_logs map[string]application_logs.Snapshot
	application_logs_errors map[string]string
	relays []ApplicationItem
	websocket_known bool
	websocket_error string
	websocket_connections int
	websocket_rooms int
	websocket_listeners []WorkspaceWebSocketListener
	known        bool
	error        string
	events_error string
	relay_error  string
	checked_at   string
	applications []RuntimeApplication
	events       []RuntimeEvent
	relay        RelayLiveStatus
}

pub fn (data RuntimeWorkspace) applications_available() bool {
	return data.known || data.inventory_known
}

pub struct WorkspaceWebSocketListener {
pub:
	listener_ids []string
	active_connections int
	active_rooms int
}

struct WorkspaceWebSockets {
	scope string
	listeners []WorkspaceWebSocketListener
	active_connections int
	active_rooms int
}

fn workspace_get(base string, token string, path string) !string {
	mut request := http.Request{
		url:                      base.trim_right('/') + path
		read_timeout:             500 * time.millisecond
		write_timeout:            300 * time.millisecond
		max_retries:              1
		allow_redirect:           false
		disable_connection_reuse: true
	}
	request.add_custom_header('x-vhttpd-admin-token', token)!
	response := request.do()!
	if response.status_code != 200 {
		return error('管理接口不可用 (${response.status_code})')
	}
	if response.body.len > 2097152 { return error('管理响应超过大小限制') }
	return response.body
}

fn fetch_workspace(base string, token string, relay RelayLiveStatus, include_relay bool) RuntimeWorkspace {
	body := workspace_get(base, token, '/admin/apps') or { return RuntimeWorkspace{ error: '无法读取运行环境中的应用；请检查连接和运行包版本。' } }
	data := json.decode[ApplicationsResponse](body) or { return RuntimeWorkspace{ error: '应用列表响应无法解析。' } }
	mut configured_relays := []ApplicationItem{}
	for group in data.apps {
		for item in group.relays {
			if !configured_relays.any(it.id == item.id) {
				configured_relays << item
			}
		}
	}
	mut applications := []RuntimeApplication{}
	for app in data.apps {
		// Management-only and resource-only groups are not deployable applications.
		if app.listeners.any(!it.control) || app.pipelines.any(it.engine != '') {
			applications << application_with_bindings(app, data.apps)
		}
	}
	mut events_error := ''
	event_body := workspace_get(base, token, '/admin/events?limit=200') or {
		events_error = '运行事件读取失败。'
		''
	}
	mut events := json.decode[[]RuntimeEvent](event_body) or {
		if events_error == '' { events_error = '运行事件响应无法解析。' }
		[]RuntimeEvent{}
	}
	mut app_logs := map[string]application_logs.Snapshot{}
	mut app_log_errors := map[string]string{}
	mut logs_unsupported := false
	mut log_applications := applications.clone()
	log_applications << RuntimeApplication{id:'*'}
	for app in log_applications {
		if logs_unsupported {
			app_log_errors[app.id] = application_log_fetch_error('管理接口不可用 (404)')
			continue
		}
		path := '/admin/logs?application='+urllib.query_escape(app.id)+'&limit=256'
		log_body := workspace_get(base,token,path) or {
			logs_unsupported = err.msg().contains('(404)')
			app_log_errors[app.id] = application_log_fetch_error(err.msg())
			continue
		}
		parsed := json.decode[application_logs.Snapshot](log_body) or {
			app_log_errors[app.id] = '应用日志响应无法解析。'
			continue
		}
		if parsed.version != 1 || (app.id != '*' && parsed.records.any(it.app_id != app.id)) {
			app_log_errors[app.id] = '应用日志归属校验失败，已拒绝显示。'
			continue
		}
		app_logs[app.id] = parsed
	}
	events.sort(a.at_unix < b.at_unix)
	if events.len > 1000 { events = events[events.len - 1000..].clone() }
	mut live := relay
	if include_relay {
		relay_body := workspace_get(base, token, '/admin/runtime/relay') or { '' }
		live = if relay_body == '' {
			RelayLiveStatus{ error: 'Relay 状态读取失败。' }
		} else {
			if parsed := json.decode[RelayLiveData](relay_body) {
				RelayLiveStatus{ known: true, checked_at: time.now().hhmmss(), data: parsed }
			} else {
				RelayLiveStatus{ error: 'Relay 状态响应无法解析。' }
			}
		}
	}
	mut ws_known := false
	mut ws_error := ''
	mut ws_state := WorkspaceWebSockets{}
	if applications.any(it.listeners.any(it.protocol == 'websocket')) {
		ws_body := workspace_get(base, token, '/admin/runtime/websocket-listeners') or { '' }
		if ws_body == '' { ws_error = '跨监听器 WebSocket 统计不可用，连接数未确认；请检查连接或更新运行包。' } else {
			if decoded := json.decode[WorkspaceWebSockets](ws_body) {if decoded.scope == 'process' {ws_state = decoded; ws_known = true} else {ws_error = 'WebSocket 统计范围未确认；未将旧接口的零值视为无连接。'}} else {ws_error = 'WebSocket 状态响应无法解析。'}
		}
	}
	return RuntimeWorkspace{ application_logs_unsupported:logs_unsupported, application_logs:app_logs, application_logs_errors:app_log_errors, websocket_known:ws_known, websocket_error:ws_error, websocket_connections:ws_state.active_connections, websocket_rooms:ws_state.active_rooms, websocket_listeners:ws_state.listeners, relays: configured_relays, known: true, checked_at: time.now().hhmmss(), applications: applications, events: events, events_error: events_error, relay: live, relay_error: live.error }
}

fn application_log_fetch_error(message string) string {
	if message.contains('(404)') {
		return '应用日志接口不可用（HTTP 404）：当前 vhttpd 运行包尚不支持应用日志。请升级当前运行环境的运行包；更新 Desktop 不会自动升级远端 vhttpd。'
	}
	if message.contains('(401)') || message.contains('(403)') {
		return '应用日志管理认证失败，请重新连接当前运行环境并检查管理认证配置。'
	}
	return '应用日志读取失败，请检查当前运行环境的管理连接。连接恢复后会自动重试。'
}

fn (mut m Manager) poll_workspace() {
	if m.token == '' || time.ticks() < m.workspace_next_probe { return }
	m.workspace_next_probe = time.ticks() + 3000
	live := fetch_workspace(m.info.admin_url.all_before('/admin/ui/'), m.token, m.relay_live, false)
	if live.known {
		m.workspace = live
	} else {
		configured := configured_workspace(m.project.config_path)
		m.workspace = RuntimeWorkspace{ ...configured, error: if configured.inventory_known { live.error } else { configured.error } }
	}
}

fn (mut m RemoteManager) poll_workspace() {
	if !m.snapshot.connected || m.snapshot.restarting || isnil(m.proxy) {
		m.workspace = RuntimeWorkspace{}
		return
	}
	if time.ticks() < m.workspace_next_probe { return }
	m.workspace_next_probe = time.ticks() + 3000
	m.workspace = fetch_workspace(m.proxy.target, m.profile.token, RelayLiveStatus{}, true)
}

pub fn (app RuntimeApplication) owns_event(event RuntimeEvent) bool {
	// More specific scope takes precedence when applications share a listener.
	if event.fields['app_id'] != '' { return event.fields['app_id'] == app.id }
	if event.fields['app'] != '' { return event.fields['app'] == app.id }
	if event.fields['pipeline_id'] != '' {
		return app.pipelines.any(it.id == event.fields['pipeline_id'])
	}
	return app.listeners.any(it.id == event.fields['listener_id'] || it.id == event.fields['listener'])
}

fn application_with_bindings(app RuntimeApplication, groups []RuntimeApplication) RuntimeApplication {
	mut engines := app.engines.clone()
	mut resources := app.resources.clone()
	for pipeline in app.pipelines {
		for group in groups {
			for engine in group.engines {
				if pipeline.engine == 'engine:' + engine.id && !engines.any(it.id == engine.id) {
					engines << engine
				}
			}
			for resource in group.resources {
				if 'resource:' + resource.id in pipeline.resources && !resources.any(it.id == resource.id) {
					resources << resource
				}
			}
		}
	}
	return RuntimeApplication{ ...app, engines: engines, resources: resources }
}
