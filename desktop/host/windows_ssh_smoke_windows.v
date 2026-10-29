module host

import os
import time

// Runs against the extracted, GUI-subsystem executable, including its real
// askpass entrypoint. Fixture credentials never refer to an external server.
pub fn run_windows_ssh_smoke() ! {
	server := RemoteServer{ id: new_remote_id()!, name: 'CI only', ssh_host: '127.0.0.1', ssh_user: 'fixture', ssh_port: 22, auth_method: 'password' }
	password := 'CI-only $ quote\' " test password'
	mut broker := new_remote_prompt_session(password, true, true)!
	defer { broker.close() }
	ticket := register_windows_session(server, broker)!
	defer { revoke_windows_session(ticket) }
	profile := RemoteProfile{ id: new_remote_id()!, name: 'fixture', ssh_host: server.ssh_host, ssh_user: server.ssh_user, ssh_port: 22, auth_method: 'password', token: 'fixture-admin' }
	environment := windows_session_environment(ticket, profile)!
	if environment.values().any(it.contains(password)) {
		return error('password_leaked_to_environment')
	}
	for attempt in 0 .. 2 {
		mut child := os.new_process(os.executable())
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
	mut helper := os.new_process(os.executable())
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
	println('PASS packaged Windows password helper, repeated session authentication, host fingerprint confirmation, credential revocation and Linux include paths')
}
