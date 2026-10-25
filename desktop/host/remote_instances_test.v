module host

import json2 as json
import net
import net.http
import os
import time

fn test_askpass_helper_entrypoint() {
	if os.getenv('VHTTPD_SSH_ASKPASS') == '1' {
		run_remote_askpass() or { eprintln(err.msg()); exit(1) }
		exit(0)
	}
}

fn test_remote_profile_rejects_command_options_and_unsupported_adapters() ! {
	good := RemoteProfile{ id: 'ab'.repeat(12), name: 'dev', ssh_host: 'dev-host', admin_port: 2018, token: 'private-token' }
	good.validate()!
	legacy := json.decode[RemoteProfile]('{"id":"${good.id}","name":"legacy","ssh_host":"dev-host","token":"private-token"}')!
	assert legacy.auth_method == 'key'
	password_profile := RemoteProfile{ ...good, auth_method: 'password' }
	password_profile.validate()!
	for p in [RemoteProfile{ ...good, ssh_host: '-F/path' },
		RemoteProfile{ ...good, ssh_host: 'host;id' },
		RemoteProfile{ ...good, ssh_user: '-oProxyCommand' }, RemoteProfile{ ...good, ssh_port: -1 },
		RemoteProfile{ ...good, restart_kind: 'systemd' },
		RemoteProfile{ ...good, token: 'bad\r\nheader' }] {
		p.validate() or { continue }
		assert false, 'unsafe or unsupported remote profile accepted'
	}
}

fn test_remote_proxy_rejects_foreign_origins_and_lifecycle_actions() ! {
	mut proxy := &RemoteProxy{ origin: 'http://127.0.0.1:21999', target: 'http://127.0.0.1:1', token: 'never-expose-token' }
	mut wrong_host := http.Request{ url: '/admin/runtime', method: .get }
	wrong_host.header.set(.host, 'attacker.example')
	assert proxy.handle(wrong_host).status_code == 403
	ticket := proxy.auth.issue_ticket(time.now().unix())!
	mut exchange := http.Request{ url: '/admin/auth/exchange', method: .post, data: 'ticket=' + ticket }
	exchange.header.set(.host, '127.0.0.1:21999')
	exchange.header.set(.origin, 'null')
	landing := proxy.handle(exchange)
	assert (landing.header.get(.connection) or { '' }) == 'close'
	assert landing.status_code == 200 && landing.body.contains('/admin/auth/complete')
	mut complete := http.Request{...exchange, url: '/admin/auth/complete'}
	complete.header.set(.origin, proxy.origin)
	response := proxy.handle(complete)
	assert response.status_code == 303
	assert !response.body.contains(proxy.token)
	assert !response.header.str().contains(proxy.token)
	assert proxy.handle(complete).status_code == 403
	complete.header.set(.origin, 'null')
	assert proxy.handle(complete).status_code == 403
	session := response.cookies()[0]
	for path in ['/admin/workbench/restart', '/admin/auth/handoff', '/admin/../outside',
		'/admin/%2e%2e/outside'] {
		mut req := http.Request{ url: path, method: .post }
		req.header.set(.host, '127.0.0.1:21999')
		req.header.set(.origin, proxy.origin)
		req.add_cookie(session)
		assert proxy.handle(req).status_code == 403
	}
	mut cross := http.Request{ url: '/admin/runtime', method: .get }
	cross.header.set(.host, '127.0.0.1:21999')
	cross.header.set(.origin, 'http://localhost:9999')
	cross.add_cookie(session)
	assert proxy.handle(cross).status_code == 403
	proxy.active = false
	assert proxy.handle(exchange).status_code == 410
}

struct RemoteTestFile {
	path     string
	original string
	value    string
}

struct RemoteTestSource {
	path string
}

struct RemoteTestWorkspaceFile {
	source RemoteTestSource
	value  string
}

struct RemoteTestWorkspace {
	config_path string
	files       []RemoteTestWorkspaceFile
}

struct RemoteTestBundle {
	config_path string
	files       []RemoteTestFile
}

fn remote_test_wait(mut m RemoteManager, restarting bool) ! {
	deadline := time.ticks() + 95000
	for time.ticks() < deadline {
		m.tick()
		if m.snapshot.connected && m.snapshot.instance.ready && (!restarting || (!m.snapshot.restarting && m.snapshot.instance.boot_id != m.expected_boot)) {
			return
		}
		if !m.snapshot.busy && !m.snapshot.connected { return error(m.snapshot.message) }
		time.sleep(80 * time.millisecond)
	}
	return error(m.snapshot.message)
}

fn remote_test_browser(m &RemoteManager, cookie http.Cookie, method http.Method, path string, body string) !http.Response {
	mut request := http.Request{ url: m.proxy.origin + path, method: method, data: body, allow_redirect: false, read_timeout: 4 * time.second }
	request.header.set(.origin, m.proxy.origin)
	if body != '' { request.header.set(.content_type, 'application/json') }
	request.add_cookie(cookie)
	return request.do()!
}

fn test_remote_ssh_browser_publish_restart_and_disconnect() ! {
	remote_host := os.getenv('VHTTPD_REMOTE_TEST_HOST')
	if remote_host == '' { return }
	password := if os.getenv('VHTTPD_REMOTE_TEST_AUTH') == 'password' { os.get_line() } else { '' }
	profile := RemoteProfile{ id: new_remote_id()!, name: 'SSH fixture', ssh_host: remote_host, auth_method: if password == '' { 'key' } else { 'password' }, admin_port: os.getenv('VHTTPD_REMOTE_TEST_PORT').int(), token: 'remote-fixture-private' }
	mut manager := &RemoteManager{ ssh_executable: os.getenv_opt('VHTTPD_REMOTE_TEST_SSH') or { '/usr/bin/ssh' } }
	defer { manager.disconnect() }
	manager.connect_with_password(profile, password)!
	if os.getenv('VHTTPD_REMOTE_TEST_UNKNOWN_HOST') == '1' {
		known := os.getenv('VHTTPD_REMOTE_TEST_KNOWN_HOSTS')
		for attempt in 0 .. 2 {
			trust_deadline := time.ticks() + 12000
			for manager.snapshot.host_key.id == '' && time.ticks() < trust_deadline { manager.tick(); time.sleep(80 * time.millisecond) }
			assert manager.snapshot.host_key.fingerprint.starts_with('SHA256:'), manager.snapshot.message + '\n' + manager.ssh_diagnostics
			assert !manager.snapshot.connected
			assert os.read_file(known)! == ''
			if attempt == 0 {
				manager.disconnect()
				assert os.read_file(known)! == ''
				manager.connect_with_password(profile, password)!
			} else {
				manager.confirm_host_key(manager.snapshot.host_key.id)!
			}
		}
	}
	remote_test_wait(mut manager, false)!
	if os.getenv('VHTTPD_REMOTE_TEST_UNKNOWN_HOST') == '1' {
		assert os.file_size(os.getenv('VHTTPD_REMOTE_TEST_KNOWN_HOSTS')) > 0
		println('PASS first-use SSH fingerprint: cancel preserves trust store; explicit confirmation records host')
	}
	before := manager.snapshot.instance
	assert before.manual_restart
	stale := manager.request(.post, '/admin/workbench/restart', json.encode({
		'operation_id':      new_remote_id()!
		'expected_boot':     'stale-boot'
		'expected_revision': before.disk_revision
	}))!
	assert stale.status_code == 409
	assert !stale.body.contains(profile.token)
	login := manager.browser_login()!
	html := os.read_file(login)!
	assert !html.contains(profile.token)
	ticket := html.all_after('name="ticket" value="').all_before('"')
	mut exchange := http.Request{ url: manager.proxy.origin + '/admin/auth/exchange', method: .post, data: 'ticket=' + ticket, allow_redirect: false }
	exchange.header.set(.origin, 'null')
	exchange.header.set(.content_type, 'application/x-www-form-urlencoded')
	landing := exchange.do()!
	assert landing.status_code == 200
	exchange.url = manager.proxy.origin + '/admin/auth/complete'
	exchange.header.set(.origin, manager.proxy.origin)
	response := exchange.do()!
	assert response.status_code == 303, response.body
	cookie := response.cookies()[0]
	assert remote_test_browser(manager, cookie, .get, '/admin/ui/', '')!.status_code == 200
	assert remote_test_browser(manager, cookie, .get, '/admin/auth/session', '')!.body.contains('true')
	// All sources and contents come from the remote API, including on Linux.
	workspace_response := remote_test_browser(manager, cookie, .get, '/admin/config/workspace', '')!
	assert workspace_response.status_code == 200
	workspace := json.decode[RemoteTestWorkspace](workspace_response.body)!
	assert workspace.config_path == before.config_path
	root := workspace.config_path
	route_files := workspace.files.filter(it.source.path.ends_with('/routes.toml'))
	extra_files := workspace.files.filter(it.source.path.ends_with('/extra.toml'))
	assert route_files.len == 1 && extra_files.len == 1
	routes, original := route_files[0].source.path, route_files[0].value
	extra, second := extra_files[0].source.path, extra_files[0].value
	bundle := RemoteTestBundle{
		config_path: root
		files:       [
			RemoteTestFile{ path: routes, original: original, value: original.replace('before', 'after') },
			RemoteTestFile{ path: extra, original: second, value: second + '# published over SSH\n' },
		]
	}
	id := 'remote-' + new_remote_id()!
	for path in ['/admin/config/changesets?id=${id}', '/admin/config/changesets/${id}/validate',
		'/admin/config/changesets/${id}/publish'] {
		result := remote_test_browser(manager, cookie, .post, path, if path.contains('?') {
			json.encode(bundle)
		} else {
			''
		})!
		assert result.status_code == 200, result.body
		assert json.decode[json.Any](result.body)!.as_map()['ok']!.bool(), result.body
	}
	manager.next_probe = 0
	manager.tick()
	assert manager.snapshot.instance.disk_revision != before.effective_revision
	manager.restart()!
	remote_test_wait(mut manager, true)!
	assert manager.snapshot.instance.effective_revision == manager.expected_revision
	assert manager.snapshot.instance.disk_revision == manager.expected_revision
	assert manager.snapshot.message.contains('已生效')
	operation := manager.snapshot.instance.operation
	assert operation.id != ''
	duplicate := manager.request(.post, '/admin/workbench/restart', json.encode({
		'operation_id':      operation.id
		'expected_boot':     operation.expected_boot
		'expected_revision': operation.expected_revision
	}))!
	assert duplicate.status_code == 202
	current_boot := manager.snapshot.instance.boot_id
	time.sleep(500 * time.millisecond)
	manager.next_probe = 0
	manager.tick()
	assert manager.snapshot.instance.boot_id == current_boot
	// Original browser session still works after the remote process has restarted.
	assert remote_test_browser(manager, cookie, .get, '/admin/runtime', '')!.status_code == 200
	manager.disconnect()
	manager.connect_with_password(profile, password)!
	remote_test_wait(mut manager, false)!
	assert manager.snapshot.instance.boot_id != before.boot_id
	assert manager.snapshot.instance.boot_id == current_boot
	assert manager.snapshot.instance.effective_revision == manager.snapshot.instance.disk_revision
	assert remote_test_browser(manager, cookie, .get, '/admin/runtime', '')!.status_code == 403

	// A different registered instance must never take over an old browser origin.
	first_origin := manager.proxy.origin
	manager.disconnect()
	other := RemoteProfile{...profile, id: new_remote_id()!, name: 'Other registered instance'}
	manager.connect_with_password(other, password)!
	remote_test_wait(mut manager, false)!
	assert manager.proxy.origin != first_origin
	login_other := manager.browser_login()!
	ticket_other := os.read_file(login_other)!.all_after('name="ticket" value="').all_before('"')
	mut exchange_other := http.Request{url: manager.proxy.origin + '/admin/auth/exchange', method: .post, data: 'ticket=' + ticket_other, allow_redirect: false}
	exchange_other.header.set(.origin, 'null')
	exchange_other.header.set(.content_type, 'application/x-www-form-urlencoded')
	assert exchange_other.do()!.status_code == 200
	exchange_other.url = manager.proxy.origin + '/admin/auth/complete'
	exchange_other.header.set(.origin, manager.proxy.origin)
	signed_in := exchange_other.do()!
	assert signed_in.status_code == 303
	assert remote_test_browser(manager, signed_in.cookies()[0], .get, '/admin/runtime', '')!.status_code == 200
	assert http.get(first_origin + '/admin/runtime')!.status_code == 410
	manager.disconnect()
	manager.connect_with_password(profile, password)!
	remote_test_wait(mut manager, false)!
	assert manager.proxy.origin == first_origin
	assert remote_test_browser(manager, signed_in.cookies()[0], .get, '/admin/runtime', '')!.status_code == 403
	println('PASS independent browser origins: inactive instance returns 410; reconnect resets login and never retargets another instance tab')
	manager.disconnect()
	manager.connect_with_password(RemoteProfile{ ...profile, token: 'wrong-fixture-secret' }, password)!
	deadline := time.ticks() + 15000
	for manager.snapshot.busy && time.ticks() < deadline {
		manager.tick()
		time.sleep(80 * time.millisecond)
	}
	assert !manager.snapshot.connected && manager.snapshot.message.contains('认证失败')
	assert !manager.snapshot.message.contains('wrong-fixture-secret')
	if password != '' {
		manager.disconnect()
		manager.connect_with_password(profile, 'incorrect-password-fixture')!
		failed_deadline := time.ticks() + 15000
		for manager.snapshot.busy && time.ticks() < failed_deadline { manager.tick(); time.sleep(80 * time.millisecond) }
		assert !manager.snapshot.connected && !manager.snapshot.busy
		assert !manager.snapshot.message.contains('incorrect-password-fixture')
		assert !manager.snapshot.message.contains(password)
		println('PASS SSH password: full lifecycle, re-entry on reconnect, wrong password rejected and redacted')
	}
	if os.getenv('VHTTPD_REMOTE_TEST_CHANGED_HOST_KEY') != '' {
		manager.disconnect()
		changed := os.read_file(os.getenv('VHTTPD_REMOTE_TEST_CHANGED_HOST_KEY'))!
		known := os.getenv('VHTTPD_REMOTE_TEST_KNOWN_HOSTS')
		os.write_file(known, changed)!
		manager.connect_with_password(profile, password)!
		changed_deadline := time.ticks() + 15000
		for manager.snapshot.busy && time.ticks() < changed_deadline { manager.tick(); time.sleep(80 * time.millisecond) }
		assert manager.snapshot.host_key_changed && !manager.snapshot.connected
		assert manager.snapshot.host_key.fingerprint.starts_with('SHA256:')
		assert os.read_file(known)! == changed
		println('PASS changed SSH host key: connection blocked; original trust record preserved')
	}
	println('PASS actual SSH: ticket login, two-file publication, detached restart, entire project effective, reconnect without stopping process, old session invalidation, wrong-token failure')
}

fn test_remote_connection_storage_roundtrip_and_duplicate_protection() ! {
	previous := os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR')
	root := os.join_path(os.temp_dir(), 'remote-profile-test-' + new_remote_id()!)
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', root, true)
	defer {
		if value := previous {
			os.setenv('VHTTPD_DESKTOP_DATA_DIR', value, true)
		} else {
			os.unsetenv('VHTTPD_DESKTOP_DATA_DIR')
		}
		os.rmdir_all(root) or {}
	}
	profile := RemoteProfile{ id: new_remote_id()!, name: 'saved instance', ssh_host: 'dev-alias', token: 'fixture-token' }
	save_remote_profiles([profile])!
	assert load_remote_profiles()! == [profile]
	assert os.stat(remote_profiles_path())!.mode & 0o077 == 0
	save_remote_profiles([profile, profile]) or {
		assert load_remote_profiles()! == [profile]
		return
	}
	assert false, 'duplicate profile replaced saved connections'
}

struct RemoteBrowserFixture {}
fn (_ RemoteBrowserFixture) handle(_ http.Request) http.Response {
	mut response := http.new_response(status: .ok, body: '<!doctype html><html><head><title>vhttpd SSH browser regression</title></head><body><h1>远端浏览器自动登录验证通过</h1><p id="parallel">并发请求验证中</p><script>Promise.all(Array.from({length:12},()=>fetch("/admin/runtime").then(r=>{if(!r.ok)throw Error("request");return r.text()}))).then(()=>document.getElementById("parallel").textContent="并发请求 12/12 已完成")</script></body></html>')
	response.header.set(.content_type, 'text/html; charset=utf-8')
	return response
}

struct BrowserFixtureProxy {
	proxy &RemoteProxy
}
fn (mut fixture BrowserFixtureProxy) handle(req http.Request) http.Response {
	eprintln('BROWSER_FLOW method=' + req.method.str() + ' path=' + req.url.all_before('?') + ' origin=' + (req.header.get(.origin) or { '' }) + ' fetch-site=' + (req.header.get_custom('sec-fetch-site') or { '' }) + ' cookie-present=' + (req.header.get(.cookie) or { '' } != '').str())
	return fixture.proxy.handle(req)
}

fn test_remote_sso_real_browser_fixture() ! {
	output := os.getenv('VHTTPD_BROWSER_FIXTURE_FILE')
	if output == '' { return }
	listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	mut upstream := &http.Server{listener: listener, handler: RemoteBrowserFixture{}, show_startup_message: false}
	spawn upstream.listen_and_serve()
	proxy_listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	origin := 'http://127.0.0.1:${proxy_listener.addr()!.port()!}'
	mut proxy := &RemoteProxy{origin: origin, target: 'http://127.0.0.1:${listener.addr()!.port()!}', token: 'browser-fixture-only'}
	mut server := &http.Server{listener: proxy_listener, handler: BrowserFixtureProxy{proxy: proxy}, show_startup_message: false, worker_num: 4}
	spawn server.listen_and_serve()
	mut manager := &RemoteManager{proxy: proxy, snapshot: RemoteSnapshot{connected: true}}
	login := manager.browser_login()!
	os.write_file(output, origin + '/admin/ui/')!
	open_local(login)!
	until := time.ticks() + 240000
	for time.ticks() < until && !os.exists(output + '.stop') { time.sleep(200 * time.millisecond) }
	server.stop()
	upstream.stop()
}

fn test_proxy_parallel_connections_do_not_starve_the_worker_pool() ! {
	listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	origin := 'http://127.0.0.1:${listener.addr()!.port()!}'
	mut proxy := &RemoteProxy{origin: origin, target: 'http://127.0.0.1:1', token: 'fixture-only'}
	mut server := &http.Server{listener: listener, handler: proxy, show_startup_message: false, worker_num: 4}
	spawn server.listen_and_serve()
	defer { server.stop() }
	for _ in 0 .. 12 {
		mut connection := net.dial_tcp(origin.all_after('http://'))!
		connection.set_read_timeout(2 * time.second)
		connection.write_string('GET /admin/auth/session HTTP/1.1\r\nHost: ' + origin.all_after('http://') + '\r\nConnection: keep-alive\r\n\r\n')!
		mut bytes := []u8{len: 2048}
		read := connection.read(mut bytes)!
		assert bytes[..read].bytestr().to_lower().contains('connection: close')
		// Keep the client socket open: the server must release it itself.
		mut end := []u8{len: 1}
		result := connection.read(mut end) or { 0 }
		assert result == 0
		connection.close() or {}
	}
}

fn test_failed_startup_never_claims_effective_or_loses_recovery_instructions() {
	instance := RemoteInstance{ready: false, manual_restart: true, disk_revision: 'target', effective_revision: 'target', operation: RemoteOperation{state: 'failed', error: 'executor_warmup_failed'}}
	matching_manifest := ConfigStatus{state: .effective, strategy: 'restart', checked_at: 'fixture'}
	for _ in 0 .. 3 {
		snapshot := remote_failed_startup_snapshot('fixture', instance, matching_manifest)
		assert snapshot.connected && !snapshot.busy && !snapshot.restarting
		assert snapshot.config_status.state == .pending && snapshot.config_status.pending
		assert snapshot.config_status.strategy == matching_manifest.strategy
		assert snapshot.message.contains('初始化失败') && snapshot.message.contains('修复后重试重启')
		assert snapshot.message.contains('不会自动重复重启')
	}
	assert instance.startup_failed()
	assert RemoteInstance{...instance, ready: true}.startup_failed()
	assert !RemoteInstance{...instance, ready: true, operation: RemoteOperation{state: 'completed'}}.startup_failed()
}

fn test_retry_does_not_mistake_the_old_failed_boot_for_a_new_failure() {
	previous := RemoteInstance{boot_id: 'old-failed', ready: false, operation: RemoteOperation{state: 'failed', error: 'executor_warmup_failed'}}
	assert remote_restart_failure_is_current(previous, false, '')
	assert !remote_restart_failure_is_current(previous, true, 'old-failed')
	assert remote_restart_failure_is_current(RemoteInstance{...previous, boot_id: 'new-failed'}, true, 'old-failed')
}
