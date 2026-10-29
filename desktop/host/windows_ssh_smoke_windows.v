module host

import os
import net.http
import time

// Runs against the extracted, GUI-subsystem executable, including its real
// askpass entrypoint. Fixture credentials never refer to an external server.
pub fn run_windows_ssh_smoke() ! {
	server := RemoteServer{ id: new_remote_id()!, name: 'CI only', ssh_host: '127.0.0.1', ssh_user: 'fixture', ssh_port: if os.getenv('VHTTPD_WINDOWS_SSH_FIXTURE_PORT').int() > 0 {
		os.getenv('VHTTPD_WINDOWS_SSH_FIXTURE_PORT').int()
	} else {
		22
	}, auth_method: 'password' }
	password := 'CI-only $ quote\' " test password'
	mut broker := new_remote_prompt_session(password, true, true)!
	defer { broker.close() }
	ticket := register_windows_session(server, broker)!
	defer { revoke_windows_session(ticket) }
	profile := RemoteProfile{ id: new_remote_id()!, name: 'fixture', ssh_host: server.ssh_host, ssh_user: server.ssh_user, ssh_port: server.ssh_port, auth_method: 'password', token: 'fixture-admin' }
	environment := windows_session_environment(ticket, profile)!
	if environment.values().any(it.contains(password)) {
		return error('password_leaked_to_environment')
	}
	for attempt in 0 .. 2 {
		mut child := os.new_process(environment['SSH_ASKPASS'])
		mut child_environment := environment.clone()
		// Win32 OpenSSH may retain the confirm hint in its parent after spawning
		// the fingerprint helper; the following actual password prompt still works.
		if attempt == 1 { child_environment['SSH_ASKPASS_PROMPT'] = 'confirm' }
		child.set_environment(child_environment)
		child.set_args(['fixture password:'])
		child.set_redirect_stdio()
		child.create_no_window = true
		child.run()
		until := time.ticks() + 5000
		for child.is_alive() && time.ticks() < until { time.sleep(20 * time.millisecond) }
		if child.is_alive() {
			child.signal_kill()
			child.wait()
			child.close()
			return error('askpass_helper_timeout')
		}
		child.wait()
		output := child.stdout_slurp()
		diagnostic := child.stderr_slurp()
		code := child.code
		child.close()
		if code != 0 || output.trim_right('\r\n') != password || diagnostic.contains(password) {
			return error('askpass_helper_failed')
		}
	}
	mut trust := new_remote_prompts('', false)!
	defer { trust.close() }
	mut helper := os.new_process(trust.environment()['SSH_ASKPASS'])
	helper.set_environment(trust.environment())
	helper.set_args(["The authenticity of host 'fixture' can't be established.\nED25519 key fingerprint is SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "])
	helper.set_redirect_stdio()
	helper.create_no_window = true
	helper.run()
	defer {
		if helper.is_alive() {
			helper.signal_kill()
			helper.wait()
		}
		helper.close()
	}
	select {
		key := <-trust.challenges {
			trust.decisions <- key.id
		}
		5 * time.second {
			return error('host_fingerprint_confirmation_timeout')
		}
	}
	until := time.ticks() + 5000
	for helper.is_alive() && time.ticks() < until { time.sleep(20 * time.millisecond) }
	if helper.is_alive() { return error('host_fingerprint_helper_timeout') }
	helper.wait()
	if helper.code != 0 || helper.stdout_slurp().trim_space() != 'yes' {
		return error('host_fingerprint_helper_failed')
	}
	if os.getenv('VHTTPD_WINDOWS_SSH_FIXTURE_PORT') != '' {
		run_windows_native_ssh_fixture(server, password)!
	}
	// A Linux include graph must be resolved independently of Windows drive paths.
	base := '/home/fixture/project'
	root := base + '/vhttpd.toml'
	source := project_templates()[0].config_text
	mut sources := map[string]string{}
	sources[root] = source.replace('version = 2', 'version = 2\ninclude = ["config/extra.toml"]')
	sources[base + '/config/extra.toml'] = 'version = 2\n'
	plan := remote_runtime_plan(root, sources)!
	if plan.control.token != 'local-development-only' { return error('remote_include_plan_failed') }
	if remote_absolute_path(base, 'config/../vhttpd.toml')! != root {
		return error('remote_path_failed')
	}
	revoke_windows_session(ticket)
	if windows_session_alive(ticket) { return error('revoked_session_available') }
	windows_smoke_note('PASS packaged Windows password helper, repeated session authentication, host fingerprint confirmation, credential revocation and Linux include paths')
}

fn run_windows_native_ssh_fixture(server RemoteServer, password string) ! {
	mut session := ServerSession{}
	session.connect(server, password)!
	defer { session.close() }
	until := time.ticks() + 15000
	mut confirmed := false
	for !session.transport_ready() && time.ticks() < until {
		select {
			key := <-session.prompts.challenges {
				if key.fingerprint != os.getenv('VHTTPD_WINDOWS_SSH_FIXTURE_FINGERPRINT') {
					return error('fixture_fingerprint_mismatch')
				}
				session.prompts.decisions <- key.id
				confirmed = true
			}
			else {
			}
		}
		part := session.process.stdout_read()
		session.ready_output += part
		if !session.process.is_alive() { return error('native_ssh_initial_auth_failed') }
		time.sleep(20 * time.millisecond)
	}
	if !session.transport_ready() || !confirmed { return error('native_ssh_initial_auth_timeout') }
	session.state = ServerSnapshot{ connected: true, server_id: server.id, control_path: session.session_reference() }
	result := session.shell('printf VHTTPD_FIXTURE_COMMAND', 10000)!
	if result.trim_space() != 'VHTTPD_FIXTURE_COMMAND' { return error('native_ssh_command_failed') }
	profile := RemoteProfile{ id: new_remote_id()!, name: 'CI fixture', ssh_host: server.ssh_host, ssh_user: server.ssh_user, ssh_port: server.ssh_port, auth_method: 'password', token: 'fixture-admin', admin_port: os.getenv('VHTTPD_WINDOWS_SSH_FIXTURE_HTTP_PORT').int() }
	mut manager := RemoteManager{}
	manager.connect_with_session(profile, '', session.session_reference())!
	defer { manager.disconnect() }
	deadline := time.ticks() + 15000
	mut forwarded := false
	for time.ticks() < deadline {
		response := http.get(manager.proxy.target + '/fixture') or {
			time.sleep(100 * time.millisecond)
			continue
		}
		if response.status_code == 200 && response.body == 'vhttpd-windows-ssh-fixture' {
			forwarded = true
			break
		}
		time.sleep(100 * time.millisecond)
	}
	if !forwarded { return error('native_ssh_forward_failed') }
	session.close()
	manager.next_probe = 0
	manager.tick()
	if manager.snapshot.connected || manager.control_path != '' || !isnil(manager.ssh) {
		return error('revoked_native_tunnel_survived')
	}
	windows_smoke_note('PASS bundled native OpenSSH first fingerprint, password authentication, subsequent command, HTTP forwarding and disconnected-session tunnel cleanup')
}

fn windows_smoke_note(message string) {
 if path := os.getenv_opt('VHTTPD_WINDOWS_SMOKE_LOG') {
  previous := os.read_file(path) or { '' }
  os.write_file(path, previous + message + '\n') or {}
 }
}
