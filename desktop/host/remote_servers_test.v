module host

import json2 as json
import net.http
import os
import time

fn test_server_helper_entrypoint() {
	if os.getenv('VHTTPD_SSH_ASKPASS') == '1' { run_remote_askpass() or { exit(1) }; exit(0) }
}

fn test_server_registration_has_no_admin_credential() ! {
	server := RemoteServer{id: 'ab'.repeat(12), name: 'empty Linux host', ssh_host: 'test-server', auth_method: 'password'}
	server.validate()!
	assert !json.encode(server).contains('token')
	assert !json.encode(server).contains('password":')
	for value in ['-oProxyCommand=bad', 'host;bad', 'host\nbad'] {
		RemoteServer{...server, ssh_host: value}.validate() or { continue }
		assert false, 'unsafe host accepted'
	}
	for name in ['../bad', 'a/b', '-unsafe', 'a\nb'] {
		validate_remote_project(ServerCommand{name: name}) or { continue }
		assert false, 'unsafe project accepted'
	}
	validate_remote_project(ServerCommand{name: 'hello-vjsx'})!
	validate_remote_project(ServerCommand{name: 'hello', admin_port: 19881}) or { return }
	assert false, 'duplicate port accepted'
}

fn server_wait_instance(mut m RemoteManager) ! {
	deadline := time.ticks() + 95000
	for time.ticks() < deadline {
		m.next_probe = 0
		m.tick()
		if m.snapshot.connected && !m.snapshot.busy && m.snapshot.instance.ready { return }
		if !m.snapshot.busy && !m.snapshot.connected { return error(m.snapshot.message) }
		time.sleep(100 * time.millisecond)
	}
	return error('remote instance timeout')
}

fn test_empty_linux_server_install_create_publish_restart() ! {
	ssh := os.getenv('VHTTPD_SERVER_TEST_SSH')
	if ssh == '' { return }
	mut s := &ServerSession{ssh_executable: ssh, scp_executable: os.getenv('VHTTPD_SERVER_TEST_SCP')}
	defer { s.close() }
	server := RemoteServer{id: new_remote_id()!, name: 'clean Linux fixture', ssh_host: 'vhttpd-fixture'}
	s.connect(server, '')!
	if os.getenv('VHTTPD_SERVER_TEST_KNOWN_HOSTS') != '' {
		known := os.getenv('VHTTPD_SERVER_TEST_KNOWN_HOSTS')
		for attempt in 0 .. 2 {
			until := time.ticks() + 12000
			for s.state.host_key.id == '' && time.ticks() < until { s.tick(); time.sleep(80 * time.millisecond) }
			assert s.state.host_key.fingerprint.starts_with('SHA256:')
			assert !s.state.connected && os.file_size(known) == 0
			if attempt == 0 { s.close(); assert os.file_size(known) == 0; s.connect(server, '')! } else {
				s.prompts.decisions <- s.state.host_key.id
				s.state = ServerSnapshot{...s.state, host_key: RemoteHostKey{}}
				s.deadline = time.ticks() + 15000
			}
		}
	}
	deadline := time.ticks() + 20000
	for !s.state.connected && time.ticks() < deadline { s.tick(); time.sleep(100 * time.millisecond) }
	assert s.state.connected, s.state.message
	assert s.state.server == server
	assert s.state.platform == 'linux-arm64'
	assert s.state.version == ''
	archive := os.getenv('VHTTPD_SERVER_TEST_PACKAGE')
	validate_remote_archive(archive, 'linux-amd64', s.job) or {
		assert err.msg().len > 0
	}
	s.install(archive)!
	assert s.state.version != ''
	s.install(archive) or { assert err.msg().contains('已安装') }
	command := ServerCommand{action: .create, name: 'hello-vjsx', web_port: os.getenv('VHTTPD_SERVER_TEST_WEB').int(), admin_port: os.getenv('VHTTPD_SERVER_TEST_ADMIN').int()}
	s.create(command)!
	p := s.state.created
	assert p.server_id == server.id && p.token.len == 64
	assert load_remote_profiles()!.any(it.id == p.id)
	// Simulate another computer: there is no local instance registration.
	save_remote_profiles([]RemoteProfile{})!
	s.inspect()!
	restored := load_remote_profiles()!
	assert restored.len == 1 && restored[0].config_path.ends_with('/instances/hello-vjsx/vhttpd.toml'), s.state.discovery_message + ' names=' + restored.map(it.name).str()
	assert restored[0].token == p.token
	// A failed older attempt may have cached a different token for the same port.
	save_remote_profiles([RemoteProfile{...restored[0], token: 'stale-local-token', config_path: ''}])!
	s.inspect()!
	assert load_remote_profiles()!.len == 1
	assert load_remote_profiles()![0].token == p.token
	// Split the generated project across includes; every subsequent check must
	// observe the whole project, rather than just its root file.
	s.shell('set -eu\ncd "$HOME/.local/share/vhttpd-workbench/instances/hello-vjsx"\nawk \'/^\\[engines.app\\]/{flag=1} flag\' vhttpd.toml > app.toml\n{ printf \'include=["app.toml"]\\n\'; awk \'/^\\[engines.app\\]/{exit} {print}\' vhttpd.toml; } > next.toml\nmv next.toml vhttpd.toml\n', 10000)!
	save_remote_profiles([]RemoteProfile{})!
	s.inspect()!
	assert load_remote_profiles()!.len == 1, s.state.discovery_message
	mut m := &RemoteManager{ssh_executable: ssh}
	defer { m.disconnect() }
	m.connect_with_session(p, '', s.state.control_path)!
	server_wait_instance(mut m)!
	assert m.snapshot.instance.disk_revision != m.snapshot.instance.effective_revision
	m.restart()!
	server_wait_instance(mut m)!
	assert m.snapshot.config_status.state == .effective
	login := m.browser_login()!
	html := os.read_file(login)!
	assert !html.contains(p.token)
	ticket := html.all_after('name="ticket" value="').all_before('"')
	mut exchange := http.Request{url: m.proxy.origin + '/admin/auth/exchange', method: .post, data: 'ticket=' + ticket, allow_redirect: false}
	exchange.header.set(.origin, 'null')
	exchange.header.set(.content_type, 'application/x-www-form-urlencoded')
	assert exchange.do()!.status_code == 200
	exchange.url = m.proxy.origin + '/admin/auth/complete'
	exchange.header.set(.origin, m.proxy.origin)
	response := exchange.do()!
	assert response.status_code == 303
	cookie := response.header.values(.set_cookie)[0].all_before(';')
	mut page := http.Request{url: m.proxy.origin + '/admin/ui/'}
	page.header.set(.cookie, cookie)
	assert page.do()!.status_code == 200
	workspace_response := m.request(.get, '/admin/config/workspace', '')!
	workspace := json.decode[json.Any](workspace_response.body)!.as_map()
	mut files := []json.Any{}
	for item in workspace['files']!.as_array() {
		file := item.as_map()
		path := file['source']!.as_map()['path']!.str()
		original := file['value']!.str()
		files << json.Any({'path': json.Any(path), 'original': json.Any(original), 'value': json.Any(if path.ends_with('/app.toml') { original.replace('thread_count = 1', 'thread_count = 2') } else { original + '\n# published through SSH\n' })})
	}
	assert files.len == 2
	body := json.encode({'config_path': json.Any(m.snapshot.instance.config_path), 'files': json.Any(files)})
	id := 'deploy-' + new_remote_id()!
	for path in ['/admin/config/changesets?id=${id}', '/admin/config/changesets/${id}/validate', '/admin/config/changesets/${id}/publish'] {
		result := m.request(.post, path, if path.contains('?') { body } else { '' })!
		assert result.status_code == 200
		assert json.decode[json.Any](result.body)!.as_map()['ok']!.bool()
	}
	m.next_probe = 0
	m.tick()
	assert m.snapshot.config_status.state == .pending
	boot := m.snapshot.instance.boot_id
	m.restart()!
	server_wait_instance(mut m)!
	assert m.snapshot.instance.boot_id != boot
	assert m.snapshot.instance.disk_revision == m.snapshot.instance.effective_revision
	assert m.snapshot.config_status.state == .effective
	m.disconnect()
	m.connect_with_session(p, '', s.state.control_path)!
	server_wait_instance(mut m)!
	assert m.snapshot.config_status.state == .effective
	// Keep the first instance running to force a real listener conflict.
	retry := ServerCommand{...command, name: 'retry-fixture'}
	mut failed := false
	s.create(retry) or { failed = true; assert !err.msg().contains(p.token) }
	assert failed
	assert load_remote_profiles()!.filter(it.name == 'retry-fixture').len == 1
	m.disconnect()
	s.shell('set -eu\ncd "$HOME/.local/share/vhttpd-workbench/instances/hello-vjsx"\nkill "$(cat runtime.pid)"\nsleep 2\n', 10000)!
	s.create(retry)!
	assert load_remote_profiles()!.filter(it.name == 'retry-fixture').len == 1
	m.connect_with_session(s.state.created, '', s.state.control_path)!
	server_wait_instance(mut m)!
	assert m.snapshot.config_status.state == .effective
	m.disconnect()
	// A terminal-started project outside the managed directory is also found.
	s.shell('set -eu\nkill "$(cat "$HOME/.local/share/vhttpd-workbench/instances/retry-fixture/runtime.pid")"\nsleep 2\nmkdir -p "$HOME/terminal-demo"\ncp "$HOME/.local/share/vhttpd-workbench/instances/retry-fixture/vhttpd.toml" "$HOME/terminal-demo/"\ncp "$HOME/.local/share/vhttpd-workbench/instances/retry-fixture/main.mjs" "$HOME/terminal-demo/"\ncd "$HOME/terminal-demo"\nnohup "$HOME/.local/share/vhttpd-workbench/runtime/vhttpd" --config "$HOME/terminal-demo/vhttpd.toml" --admin-token terminal-runtime-only --manual-restart > process.log 2>&1 < /dev/null &\nsleep 2\n', 12000)!
	save_remote_profiles([]RemoteProfile{})!
	s.inspect()!
	terminal := load_remote_profiles()!.filter(it.name == 'terminal-demo')
	assert terminal.len == 1, s.state.discovery_message
	assert terminal[0].token == 'terminal-runtime-only'
	m.connect_with_session(terminal[0], '', s.state.control_path)!
	server_wait_instance(mut m)!
	assert m.snapshot.connected && m.snapshot.instance.ready
	m.disconnect()
	if os.getenv('VHTTPD_SERVER_TEST_CHANGED_HOST') != '' {
		s.close()
		known := os.getenv('VHTTPD_SERVER_TEST_KNOWN_HOSTS')
		changed := os.read_file(os.getenv('VHTTPD_SERVER_TEST_CHANGED_HOST'))!
		os.write_file(known, changed)!
		s.connect(server, '')!
		until := time.ticks() + 12000
		for !s.state.error && time.ticks() < until { s.tick(); time.sleep(80 * time.millisecond) }
		assert s.state.error && s.state.host_key_changed
		assert os.read_file(known)! == changed
	}
	println('PASS empty Linux server: install, fresh-computer discovery, stale-token repair, cross-include discovery, browser Admin 200, publication, restart/effective, terminal-project discovery with live CLI credential and reconnect')
}

fn test_discovered_profile_uses_remote_sources_without_local_files() ! {
	path := '/remote-only/hello/vhttpd.toml'
	server := RemoteServer{id: 'ab'.repeat(12), name: 'Fixture', ssh_host: 'fixture'}
	profile := discovered_profile(server, RemoteProjectCandidate{path: path}, {path: project_templates()[0].config_text})!
	assert profile.admin_port == 19981 && profile.token == 'local-development-only'
	assert profile.config_path == path
}

fn test_process_discovery_and_cache_reconciliation_preserve_project_identity() ! {
	candidate := running_project_candidate('/remote/a folder', 'vhttpd\x00--config\x00config.toml\x00--admin-token\x00live-token\x00')!
	assert candidate.path == '/remote/a folder/config.toml' && candidate.token == 'live-token'
	assert running_project_candidate('/remote/default', 'vhttpd\x00')!.path == '/remote/default/vhttpd.toml'
	a := RemoteProfile{id: 'ab'.repeat(12), server_id: 'one', name: 'A', ssh_host: 'fixture', token: 'old', config_path: '/remote/a.toml'}
	b := RemoteProfile{id: 'cd'.repeat(12), server_id: 'two', name: 'B', ssh_host: 'fixture2', token: 'other', config_path: '/remote/a.toml'}
	remote := RemoteProfile{...a, id: 'ef'.repeat(12), token: 'actual', admin_port: 9090}
	merged := merge_discovered_profiles([a, b], [remote])
	assert merged.len == 2 && merged[0].id == a.id && merged[0].token == 'actual'
	assert merged[0].admin_port == 9090 && merged[1] == b
	assert merge_discovered_profiles(merged, [remote]) == merged
}
