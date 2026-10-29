module host

import json2 as json
import encoding.base64
import net.http
import net
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
	assert s.state.runtimes.len == 1
	mut first_runtime := s.state.runtimes[0]
	s.install(archive)!
	assert s.state.runtimes.len == 1 && s.state.runtimes[0] == first_runtime
 if os.getenv('VHTTPD_SERVER_TEST_UPGRADE') == '1' || os.getenv('VHTTPD_SERVER_TEST_DEPLOY') == '1' {
  // Match an existing Desktop installation: a legacy runtime directory remains
  // in place, and the old instance has no per-instance version marker yet.
  s.shell('set -eu\ncp -R ' + shell_quote(first_runtime.path) + ' "$HOME/.local/share/vhttpd-workbench/runtime"\n',10000)!
  s.inspect()!
  first_runtime = s.state.runtimes.filter(it.id == 'legacy')[0]
 }
	command := ServerCommand{action: .create, runtime_id: first_runtime.id, name: 'hello-vjsx', web_port: os.getenv('VHTTPD_SERVER_TEST_WEB').int(), admin_port: os.getenv('VHTTPD_SERVER_TEST_ADMIN').int()}
	s.create(command)!
	p := s.state.created
	assert p.server_id == server.id && p.token.len == 64
	assert p.runtime_id == first_runtime.id && p.runtime_path == first_runtime.path + '/vhttpd'
 if first_runtime.id == 'legacy' { s.shell('rm ' + shell_quote(os.dir(p.config_path) + '/.desktop-runtime-id'),5000)! }
	assert load_remote_profiles()!.any(it.id == p.id)
	// Simulate another computer: there is no local instance registration.
	save_remote_profiles([]RemoteProfile{})!
	s.inspect()!
	restored := load_remote_profiles()!
	assert restored.len == 1 && restored[0].config_path.ends_with('/instances/hello-vjsx/vhttpd.toml'), s.state.discovery_message + ' names=' + restored.map(it.name).str()
	assert restored[0].token == p.token
	assert restored[0].runtime_id == p.runtime_id
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
		assert result.status_code == 200, path + ": " + result.body
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
	// Installing a second immutable package must not alter the first running instance.
	before_install_boot := m.snapshot.instance.boot_id
	second_archive := os.getenv('VHTTPD_SERVER_TEST_SECOND_PACKAGE')
	mut retry_runtime := first_runtime
	if second_archive != '' {
		s.install_release(second_archive, 'v0.1.0-dev.fixture')!
		assert s.state.runtimes.len == if first_runtime.id == 'legacy' { 3 } else { 2 }
		retry_runtime = s.state.runtimes.filter(it.release_tag == 'v0.1.0-dev.fixture')[0]
		assert retry_runtime.path != first_runtime.path
		assert retry_runtime.release_tag == 'v0.1.0-dev.fixture'
		m.next_probe = 0
		m.tick()
		assert m.snapshot.instance.boot_id == before_install_boot && m.snapshot.instance.ready
		assert load_remote_profiles()!.filter(it.name == p.name)[0].runtime_path == p.runtime_path
		mut refused_rebind := false
		s.create(ServerCommand{...command, runtime_id: retry_runtime.id}) or { refused_rebind = true; assert err.msg().contains('绑定其他运行包') }
		assert refused_rebind
	}
 if os.getenv('VHTTPD_SERVER_TEST_DEPLOY')=='1' { server_application_acceptance(mut s,p,command.web_port)! }
 if os.getenv('VHTTPD_SERVER_TEST_UPGRADE') == '1' {
  // Pending include changes must be refused without stopping the healthy process.
  s.shell('set -eu\np=' + shell_quote(os.dir(p.config_path) + '/app.toml') + '\ncp "$p" "$p.before-upgrade"\nprintf "\\n# pending-upgrade-fixture\\n" >> "$p"\n', 5000)!
  mut pending_refused := false
  s.upgrade(ServerCommand{action: .upgrade, project_id: p.id, runtime_id: retry_runtime.id}) or { pending_refused = true }
  assert pending_refused
  m.next_probe = 0; m.tick()
  assert m.snapshot.instance.boot_id == before_install_boot && m.snapshot.instance.ready
  s.shell('set -eu\np=' + shell_quote(os.dir(p.config_path) + '/app.toml') + '\nmv "$p.before-upgrade" "$p"\n', 5000)!
  // The original runtime predates the upgrade protocol. Automatic recovery must
  // still be able to launch it without requiring a helper in that old package.
  legacy_failure_archive := os.getenv('VHTTPD_SERVER_TEST_FAILURE_PACKAGE')
  assert legacy_failure_archive != ''
  s.install_release(legacy_failure_archive, 'v0.0.0-dev.failure-fixture') or { archive_fixture_diagnostic(legacy_failure_archive); return error('initial rollback fixture package: ' + err.msg()) }
  legacy_failing := s.state.runtimes.filter(it.version == '0.0.0-failure-fixture')[0]
  s.upgrade(ServerCommand{action: .upgrade, project_id: p.id, runtime_id: legacy_failing.id})!
  legacy_operation := s.state.upgrades.filter(it.config_path == p.config_path)[0].id
  server_wait_upgrade(mut s, legacy_operation, 'rolled_back')!
  assert s.state.projects.filter(it.id == p.id)[0].runtime_id == first_runtime.id
  server_wait_instance(mut m)!
  assert server_upgrade_business(s, command.web_port)!.status_code == 200
  s.upgrade(ServerCommand{action: .upgrade, project_id: p.id, runtime_id: retry_runtime.id})!
  operation := s.state.upgrades.filter(it.config_path == p.config_path)[0].id
  m.disconnect()
  // Recovery belongs to the remote helper, rather than the Desktop SSH session.
  s.close()
  s.connect(server, '')!
  reconnect_until := time.ticks() + 20000
  for !s.state.connected && time.ticks() < reconnect_until { s.tick(); time.sleep(100 * time.millisecond) }
  assert s.state.connected
  server_wait_upgrade(mut s, operation, 'completed')!
  updated := s.state.projects.filter(it.id == p.id)[0]
  assert updated.runtime_id == retry_runtime.id && updated.runtime_path == retry_runtime.path + '/vhttpd'
  m.connect_with_session(updated, '', s.state.control_path)!
  server_wait_instance(mut m)!
  assert m.snapshot.instance.boot_id != before_install_boot
  assert server_upgrade_business(s, command.web_port)!.status_code == 200
  assert m.snapshot.config_status.state == .effective
  upgrade_boot := m.snapshot.instance.boot_id
  upgrade_revision := m.snapshot.instance.effective_revision
  // An old target without the safety protocol must be rejected before downtime.
  mut unsupported := false
  s.upgrade(ServerCommand{action: .upgrade, project_id: p.id, runtime_id: first_runtime.id}) or { unsupported = true }
  assert unsupported
  m.next_probe = 0; m.tick()
  assert m.snapshot.instance.boot_id == upgrade_boot
  failing_archive := os.getenv('VHTTPD_SERVER_TEST_FAILURE_PACKAGE')
  assert failing_archive != ''
  s.install_release(failing_archive, 'v0.0.0-dev.failure-fixture') or { archive_fixture_diagnostic(failing_archive); return error('second rollback fixture package: ' + err.msg()) }
  failing := s.state.runtimes.filter(it.version == '0.0.0-failure-fixture')[0]
  s.upgrade(ServerCommand{action: .upgrade, project_id: p.id, runtime_id: failing.id})!
  failure_operation := s.state.upgrades.filter(it.config_path == p.config_path)[0].id
  server_wait_upgrade(mut s, failure_operation, 'rolled_back')!
  assert s.state.projects.filter(it.id == p.id)[0].runtime_id == retry_runtime.id
  m.next_probe = 0; server_wait_instance(mut m)!
  assert m.snapshot.instance.ready && m.snapshot.config_status.state == .effective
  assert m.snapshot.instance.effective_revision == upgrade_revision
  assert m.snapshot.instance.boot_id != upgrade_boot
  assert server_upgrade_business(s, command.web_port)!.status_code == 200
  // Credentials are removed when a transaction ends; public outcome has no token.
  secret_path := os.dir(p.config_path) + '/.desktop-upgrades/' + failure_operation + '/request.json'
  assert s.shell('[ ! -e ' + shell_quote(secret_path) + ' ] && printf clean', 5000)! == 'clean'
  println('PASS detached runtime upgrade, reconnect, unsupported target refusal, failed-start automatic rollback and unchanged whole-project revision')
 }
	// Keep the first instance running to force a real listener conflict.
	retry := ServerCommand{...command, name: 'retry-fixture', runtime_id: retry_runtime.id}
	mut failed := false
	s.create(retry) or { failed = true; assert !err.msg().contains(p.token) }
	assert failed
	assert load_remote_profiles()!.filter(it.name == 'retry-fixture').len == 1
	m.disconnect()
	s.shell('set -eu\ncd "$HOME/.local/share/vhttpd-workbench/instances/hello-vjsx"\nkill "$(cat runtime.pid)"\nsleep 2\n', 10000)!
	s.create(retry)!
	assert s.state.created.runtime_id == retry_runtime.id
	assert load_remote_profiles()!.filter(it.name == 'retry-fixture').len == 1
	m.connect_with_session(s.state.created, '', s.state.control_path)!
	server_wait_instance(mut m)!
	assert m.snapshot.config_status.state == .effective
	m.disconnect()
	// Keep the legacy directory and its stopped projects recognizable alongside new packages.
	s.shell('set -eu\nif [ ! -d "$HOME/.local/share/vhttpd-workbench/runtime" ]; then cp -R ' + shell_quote(first_runtime.path) + ' "$HOME/.local/share/vhttpd-workbench/runtime"; fi\nmkdir "$HOME/.local/share/vhttpd-workbench/instances/legacy-stopped"\ncp "$HOME/.local/share/vhttpd-workbench/instances/retry-fixture/vhttpd.toml" "$HOME/.local/share/vhttpd-workbench/instances/legacy-stopped/"\n', 10000)!
	s.inspect()!
	assert s.state.runtimes.any(it.id == 'legacy')
	assert s.state.projects.filter(it.name == 'legacy-stopped')[0].runtime_id == 'legacy'
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

fn test_remote_runtime_inventory_requires_explicit_version_selection() ! {
	id := 'sha256-' + 'ab'.repeat(32)
	lines := ['VHTTPD_RUNTIME:legacy:' + base64.encode_str('vhttpd 0.1.0') + ':', 'VHTTPD_RUNTIME:' + id + ':' + base64.encode_str('vhttpd 0.1.0') + ':' + base64.encode_str('v0.1.0-dev.fixture')]
	items := parse_remote_runtimes(lines, '/home/fixture/.local/share/vhttpd-workbench')!
	assert items.len == 2 && items[0].path.ends_with('/runtime') && items[1].path.ends_with('/runtimes/' + id)
	assert select_remote_runtime([items[0]], '')! == items[0]
	assert select_remote_runtime(items, id)! == items[1]
	mut rejected := false
	select_remote_runtime(items, '') or { rejected = true }
	assert rejected
	for invalid in ['../runtime', 'sha256-bad', ''] { assert !remote_runtime_id_valid(invalid) }
	rejected = false
	parse_remote_runtimes([lines[0], lines[0]], '/fixture') or { rejected = true }
	assert rejected
}

fn server_wait_upgrade(mut s ServerSession, id string, expected string) ! {
 until := time.ticks() + 240000
 for time.ticks() < until {
  s.poll_upgrades()!
  matches := s.state.upgrades.filter(it.id == id)
  if matches.len == 1 && matches[0].finished() {
   if matches[0].phase != expected {
    log_path := os.dir(matches[0].config_path) + '/.desktop-upgrades/' + id + '/runtime.log'
    encoded := s.shell('tail -c 8192 ' + shell_quote(log_path) + ' | base64', 5000) or { '' }
    mut diagnostics := base64.decode_str(encoded.replace('\n',''))
    for profile in s.state.projects { diagnostics = diagnostics.replace(profile.token, '[redacted]') }
    eprintln('UPGRADE_FIXTURE_LOG: ' + diagnostics)
   }
   assert matches[0].phase == expected, matches[0].str()
   return
  }
  time.sleep(200 * time.millisecond)
 }
 return error('remote upgrade did not finish')
}

fn server_upgrade_business(s &ServerSession, remote_port int) !http.Response {
 mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
 port := listener.addr()!.port()!
 listener.close()!
 binding := '127.0.0.1:${port}:127.0.0.1:${remote_port}'
 mut args := s.mux_args()
 args << ['-O','forward','-L',binding]
 args << s.destination_args()
 s.job.command(s.ssh_executable,args,6000)!
 defer {
  mut cancel := s.mux_args()
  cancel << ['-O','cancel','-L',binding]
  cancel << s.destination_args()
  s.job.command(s.ssh_executable,cancel,6000) or {}
 }
 return http.get('http://127.0.0.1:${port}/')
}

fn test_upgrade_helpers_are_not_discovered_as_serving_instances() {
 for flag in ['--workbench-upgrade-check','--workbench-upgrade-helper','--workbench-restart-helper','--workbench-deploy-helper','--workbench-deploy-prepare','--workbench-deploy-version'] {
  mut refused := false
  running_project_candidate('/remote', 'vhttpd\x00' + flag + '\x00/remote/vhttpd.toml\x00') or { refused = true }
  assert refused
 }
}

fn archive_fixture_diagnostic(path string) {
 result := os.execute('/usr/bin/tar -tvzf ' + shell_quote(path))
 eprintln('FIXTURE_ARCHIVE_CHECK code=' + result.exit_code.str() + ' ' + result.output.limit(1200))
}

struct ApplicationTestSource { path string }
struct ApplicationTestFile { source ApplicationTestSource
 value string }
struct ApplicationTestWorkspace { files []ApplicationTestFile }

fn application_wait(mut s ServerSession,id string,phase string) ! {
 until := time.ticks()+110000
 for time.ticks()<until {
  s.poll_deployments()!
  statuses := s.state.deployments.filter(it.id==id)
  if statuses.len==1 && statuses[0].finished() {
   if statuses[0].phase!=phase { return error('unexpected application deployment result: '+statuses[0].phase+' '+statuses[0].error) }
   return
  }
  time.sleep(100*time.millisecond)
 }
 return error('application deployment timeout')
}
fn server_application_acceptance(mut s ServerSession,p RemoteProfile,port int) ! {
 root := os.join_path(os.real_path(os.temp_dir()),'vh-deploy-client-'+new_remote_id()!)
 os.mkdir(root,mode:0o700)!
 defer { os.rmdir_all(root) or {} }
 original := root+'/original'; local := root+'/local'
 for dir in [original,local] { os.mkdir_all(dir)! }
 mut manager := &RemoteManager{}
 manager.connect_with_session(p,'',s.state.control_path)!
 defer { manager.disconnect() }
 server_wait_instance(mut manager)!
 workspace := json.decode[ApplicationTestWorkspace](manager.request(.get,'/admin/config/workspace','')!.body)!
 for file in workspace.files { os.write_file(os.join_path(original,os.file_name(file.source.path)),file.value)! }
 source := s.shell('base64 < '+shell_quote(os.dir(p.config_path)+'/main.mjs'),5000)!
 os.write_file(original+'/main.mjs',base64.decode_str(source.replace('\n','')))!
 os.mkdir_all(local+'/config')!; os.mkdir_all(local+'/public')!
 template := project_templates()[0]
 config_text := template.config_text.replace('entry = "main.mts"','entry = "main.mjs"').replace('runtime_profile = "node"','runtime_profile = "node"')
 pos := config_text.index('[engines.app]') or { return error('missing engine') }
 routes := config_text.index('[[pipelines]]') or { return error('missing route') }
 os.write_file(local+'/vhttpd.toml','include=["config/engines.toml","config/routes.toml"]\n'+config_text[..pos])!
 os.write_file(local+'/config/engines.toml',config_text[pos..routes].replace('entry = "main.mjs"','entry = "../main.mjs"'))!
 os.write_file(local+'/config/routes.toml',config_text[routes..])!
 code_a := 'import fs from "fs"; export default function(c) { return c.json({release:"A",asset:fs.readFileSync("public/banner.txt").toString("utf8")},200); }'
 code_b := code_a.replace('release:"A"','release:"B"')
 os.write_file(local+'/main.mjs',code_a)!
 os.write_file(local+'/public/banner.txt','asset-A')!; os.write_file(local+'/public/obsolete.txt','obsolete-A')!
 os.write_file(local+'/.env','LOCAL-ENV-MUST-NOT-UPLOAD')!
 s.shell('printf REMOTE-ENV > '+shell_quote(os.dir(p.config_path)+'/.env')+'\nprintf REMOTE-DATA > '+shell_quote(os.dir(p.config_path)+'/user-data.txt'),5000)!
 project := Project{name:'local application',workdir:local,config_path:local+'/vhttpd.toml'}
 prepare := ServerCommand{action:.prepare_deploy,project_id:p.id,local_project:project}
 baseline := manager.snapshot.instance
 s.prepare_application(prepare)!
 assert s.state.deployment_preview.files.any(it.path=='config/routes.toml')
 assert !s.state.deployment_preview.files.any(it.path=='.env')
 // Local changes after preview must be rejected before any remote stop.
 os.write_file(local+'/main.mjs',code_a+'\n// after preview')!
 mut refused := false
 s.deploy_application(ServerCommand{deployment_id:s.state.deployment_preview.id}) or { refused=true }
 assert refused
 manager.next_probe=0; manager.tick(); assert manager.snapshot.instance.boot_id==baseline.boot_id
 os.write_file(local+'/main.mjs',code_a)!
 s.prepare_application(prepare)!
 first := s.state.deployment_preview.id
 s.deploy_application(ServerCommand{deployment_id:first})!
 // Deployment is independent of the SSH master and Desktop lifecycle.
 server := s.server
 s.close(); s.connect(server,'')!
 until := time.ticks()+20000
 for !s.state.connected && time.ticks()<until { s.tick(); time.sleep(80*time.millisecond) }
 assert s.state.connected
 application_wait(mut s,first,'completed')!
 manager.disconnect(); manager.connect_with_session(p,'',s.state.control_path)!; server_wait_instance(mut manager)!
 assert manager.snapshot.instance.boot_id!=baseline.boot_id
 assert manager.snapshot.config_status.state==.effective
 assert manager.profile.admin_port==p.admin_port && manager.profile.token==p.token
 response_a := server_upgrade_business(s,port)!
 assert response_a.status_code==200 && response_a.body.contains('asset-A')
 revision_a := manager.snapshot.instance.effective_revision
 // A valid config with an app warmup failure must restore ALL file kinds,
 // including a removed asset and a newly introduced asset.
 os.write_file(local+'/main.mjs','throw new Error("intentional deployment warmup failure"); export default c=>c.text("bad");')!
 os.write_file(local+'/public/banner.txt','asset-B')!; os.rm(local+'/public/obsolete.txt')!; os.write_file(local+'/public/new.txt','new-B')!
 s.prepare_application(prepare)!
 failed := s.state.deployment_preview.id
 s.deploy_application(ServerCommand{deployment_id:failed})!
 application_wait(mut s,failed,'rolled_back')!
 manager.next_probe=0; manager.tick(); server_wait_instance(mut manager)!
 assert manager.snapshot.instance.effective_revision==revision_a
 assert server_upgrade_business(s,port)!.body.contains('asset-A')
 assert s.shell('cat '+shell_quote(os.dir(p.config_path)+'/public/obsolete.txt'),5000)! == 'obsolete-A'
 assert s.shell('test ! -f '+shell_quote(os.dir(p.config_path)+'/public/new.txt')+' && printf yes',5000)! == 'yes'
 // Fix the source, redeploy, and ensure removed managed files stay removed.
 os.write_file(local+'/main.mjs',code_b)!
 s.prepare_application(prepare)!
 retry := s.state.deployment_preview.id
 s.deploy_application(ServerCommand{deployment_id:retry})!
 application_wait(mut s,retry,'completed')!
 assert server_upgrade_business(s,port)!.body.contains('asset-B')
 assert s.shell('test ! -f '+shell_quote(os.dir(p.config_path)+'/public/obsolete.txt')+' && printf yes',5000)! == 'yes'
 assert s.shell('cat '+shell_quote(os.dir(p.config_path)+'/.env')+'; cat '+shell_quote(os.dir(p.config_path)+'/user-data.txt'),5000)! == 'REMOTE-ENVREMOTE-DATA'
 // Restore the original test app through the same verified deployment flow.
 s.prepare_application(ServerCommand{action:.prepare_deploy,project_id:p.id,local_project:Project{workdir:original,config_path:original+'/vhttpd.toml'}})!
 restore := s.state.deployment_preview.id
 s.deploy_application(ServerCommand{deployment_id:restore})!
 application_wait(mut s,restore,'completed')!
 println('PASS application deploy: cross-include, source/assets, remote ports/auth/data, stale preview refusal, detached SSH, warmup rollback, retry and managed asset deletion')
}
