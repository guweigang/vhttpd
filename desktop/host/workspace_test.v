module host

import net
import net.http
import time

fn test_application_events_use_exact_scope_not_substring_or_payload() {
	app := RuntimeApplication{ id: 'paseo', listeners: [ApplicationListener{ id: 'paseo-ws' }], pipelines: [ApplicationPipeline{ id: 'paseo.relay' }] }
	assert app.owns_event(RuntimeEvent{
		fields: {
			'listener_id': 'paseo-ws'
		}
	})
	assert app.owns_event(RuntimeEvent{
		fields: {
			'pipeline_id': 'paseo.relay'
		}
	})
	assert app.owns_event(RuntimeEvent{
		fields: {
			'app_id': 'paseo'
		}
	})
	assert !app.owns_event(RuntimeEvent{
		fields: {
			'listener_id': 'paseo-ws-other'
		}
	})
	assert !app.owns_event(RuntimeEvent{
		fields: {
			'message': 'paseo'
			'path':    '/paseo'
		}
	})
}

struct WorkspaceFixture {
	legacy bool
	mixed bool
}

fn (h WorkspaceFixture) handle(req http.Request) http.Response {
	if (req.header.get_custom('x-vhttpd-admin-token') or { '' }) != 'workspace-fixture' {
		return http.Response{ status_code: 401, body: '{}' }
	}
	if h.legacy && (req.url.starts_with('/admin/runtime/websocket-listeners') || req.url.starts_with('/admin/logs')) {return http.Response{status_code:404,body:'{}'}}
	body := match req.url.all_before('?') {
		'/admin/apps' {
			'{"apps":[{"id":"database","relays":[{"id":"bodytest_database","kind":"hub"}]},{"id":"admin","listeners":[{"id":"admin","control":true}]},{"id":"bodytest","label":"Bodytest","listeners":[{"id":"web","port":19887}],"pipelines":[{"id":"bodytest.http","ingress":"listener:web","engine":"engine:bodytest"}]},{"id":"paseo","label":"Paseo","listeners":[{"id":"paseo","protocol":"websocket","port":19901}],"pipelines":[{"id":"paseo.relay","ingress":"listener:paseo","engine":"engine:paseo"}]}]}'
		}
		'/admin/events' {
			'[{"id":"1","type":"http.request","at_unix":123,"fields":{"listener_id":"paseo","path":"/meta"}}]'
		}
		'/admin/logs' {
			id := if h.mixed {'wrong-app'} else if req.url.contains('application=paseo') {'paseo'} else if req.url.contains('application=bodytest') {'bodytest'} else {'bodytest'}
			'{"version":1,"records":[{"id":1,"app_id":"'+id+'","source":"console","message":"'+id+'-output"}]}'
		}
		'/admin/runtime/websocket-listeners' {
			'{"scope":"process","active_connections":1,"active_rooms":1,"listeners":[{"listener_ids":["paseo"],"active_connections":1,"active_rooms":1}]}'
		}
		'/admin/runtime/relay' {
			'{"open_channels":1,"agents":[{"relay_id":"edge","state":"connected"}]}'
		}
		else { '{}' }
	}
	return http.Response{ status_code: 200, body: body }
}

fn test_workspace_fetch_uses_authenticated_runtime_projection_for_two_apps() ! {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := listener.addr()!.port()!
	mut server := &http.Server{ listener: listener, handler: WorkspaceFixture{}, show_startup_message: false, accept_timeout: 50 * time.millisecond }
	spawn server.listen_and_serve()
	defer { server.stop() }
	url := 'http://127.0.0.1:${port}'
	status := fetch_workspace(url, 'workspace-fixture', RelayLiveStatus{}, true)
	assert status.known, status.error
	assert status.relays.len == 1 && status.relays[0].id == 'bodytest_database'
	assert status.applications.map(it.id) == ['bodytest', 'paseo']
	assert status.events.len == 1 && status.applications[1].owns_event(status.events[0])
	assert status.application_logs['bodytest'].records[0].message == 'bodytest-output'
	assert status.application_logs['paseo'].records[0].message == 'paseo-output'
	assert status.relay.known && status.relay.data.open_channels == 1
	assert status.websocket_known && status.websocket_connections == 1
	assert status.websocket_listeners[0].listener_ids == ['paseo']
	assert !fetch_workspace(url, 'wrong-credential', RelayLiveStatus{}, true).known
}

fn test_application_bindings_follow_references_across_shared_config_groups() {
	app := RuntimeApplication{ id: 'bodytest', pipelines: [ApplicationPipeline{ id: 'bodytest.http', engine: 'engine:app', resources: ['resource:db/wechat'] }] }
	groups := [
		RuntimeApplication{ id: 'app', engines: [ApplicationItem{ id: 'app', kind: 'vjsx' }] },
		RuntimeApplication{ id: 'wechat', resources: [ApplicationItem{ id: 'db/wechat', kind: 'mysql' }] },
		RuntimeApplication{ id: 'unrelated', resources: [ApplicationItem{ id: 'db/other', kind: 'mysql' }] },
	]
	resolved := application_with_bindings(app, groups)
	assert resolved.engines.map(it.id) == ['app']
	assert resolved.resources.map(it.id) == ['db/wechat']
}

fn test_shared_listener_never_overrides_another_app_or_pipeline_scope() {
	app := RuntimeApplication{ id: 'paseo', listeners: [ApplicationListener{ id: 'shared-web' }], pipelines: [ApplicationPipeline{ id: 'paseo.http' }] }
	assert !app.owns_event(RuntimeEvent{ fields: {
		'app_id':      'bodytest'
		'listener_id': 'shared-web'
	} })
	assert !app.owns_event(RuntimeEvent{ fields: {
		'pipeline_id': 'bodytest.http'
		'listener_id': 'shared-web'
	} })
	assert app.owns_event(RuntimeEvent{ fields: {
		'pipeline_id': 'paseo.http'
		'listener_id': 'shared-web'
	} })
}

fn test_legacy_runtime_does_not_claim_secondary_websocket_has_zero_connections() ! {
	mut listener := net.listen_tcp(.ip,'127.0.0.1:0')!
	port := listener.addr()!.port()!
	mut server := &http.Server{listener:listener,handler:WorkspaceFixture{legacy:true},show_startup_message:false,accept_timeout:50*time.millisecond}
	spawn server.listen_and_serve()
	defer {server.stop()}
	status := fetch_workspace('http://127.0.0.1:${port}','workspace-fixture',RelayLiveStatus{},true)
	assert status.known && !status.websocket_known
	assert status.websocket_error.contains('连接数未确认')
	assert status.application_logs_errors['bodytest'].contains('应用日志接口不可用')
	assert status.application_logs_unsupported
	assert status.application_logs_errors['bodytest'].contains('HTTP 404')
	assert status.application_logs_errors['bodytest'].contains('更新 Desktop 不会自动升级远端')
	assert 'bodytest' !in status.application_logs
}

fn test_application_log_errors_distinguish_authentication_and_missing_support() {
	assert application_log_fetch_error('管理接口不可用 (403)').contains('认证失败')
	assert !application_log_fetch_error('管理接口不可用 (403)').contains('请升级')
	assert application_log_fetch_error('timeout').contains('连接恢复后会自动重试')
}

fn test_workspace_rejects_a_log_batch_with_another_application_identity() ! {
 mut listener := net.listen_tcp(.ip,'127.0.0.1:0')!
 port := listener.addr()!.port()!
 mut server := &http.Server{listener:listener,handler:WorkspaceFixture{mixed:true},show_startup_message:false,accept_timeout:50*time.millisecond}
 spawn server.listen_and_serve()
 defer {server.stop()}
 status := fetch_workspace('http://127.0.0.1:${port}','workspace-fixture',RelayLiveStatus{},true)
 assert 'bodytest' !in status.application_logs
 assert status.application_logs_errors['bodytest'].contains('归属校验失败')
}
