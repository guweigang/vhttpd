module host

import net.unix
import os
import json2 as json
import time

fn test_host_key_confirmation_requires_matching_decision_and_can_be_cancelled() ! {
	prompt := "The authenticity of host 'fixture (127.0.0.1)' can't be established.\nED25519 key fingerprint is: SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "
	for confirm in [true, false] {
		mut session := new_remote_prompts('', false)!
		mut connection := unix.connect_stream(session.path)!
		connection.write_string(session.capability + '\n' + json.encode(RemotePromptRequest{kind: 'host_key', prompt: prompt}) + '\n')!
		mut challenge := RemoteHostKey{}
		select {
			key := <-session.challenges { challenge = key }
			2 * time.second { assert false, 'host challenge missing' }
		}
		assert challenge.algorithm == 'ED25519'
		assert challenge.fingerprint == 'SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG'
		if confirm {
			session.decisions <- challenge.id
			assert read_askpass_line(mut connection, 4096)! == 'yes'
		} else {
			session.close()
			mut data := []u8{len: 1}
			assert connection.read(mut data) or { 0 } == 0
		}
		connection.close()!
		session.close()
		assert !os.exists(session.directory)
	}
}

fn test_ssh_password_is_one_shot_and_absent_from_environment_and_profiles() ! {
	password := 'fixture $ quote\' " 空格 secret'
	mut session := new_remote_prompts(password, true)!
	defer { session.close() }
	assert os.stat(session.directory)!.mode & 0o077 == 0
	assert os.stat(session.path)!.mode & 0o077 == 0
	assert os.ls(session.directory)! == ['auth']
	assert !session.environment().values().any(it.contains(password))
	profile := RemoteProfile{id: new_remote_id()!, name: 'password fixture', ssh_host: 'localhost', auth_method: 'password', token: 'admin-fixture'}
	assert !json.encode(profile).contains(password)
	assert !json.encode(profile).contains('password":')
	mut rejected := unix.connect_stream(session.path)!
	rejected.write_string('wrong-capability\n')!
	mut data := []u8{len: 1}
	assert rejected.read(mut data) or { 0 } == 0
	rejected.close()!
	mut connection := unix.connect_stream(session.path)!
	connection.write_string(session.capability + '\n' + json.encode(RemotePromptRequest{kind: 'password'}) + '\n')!
	assert read_askpass_line(mut connection, 4096)! == password
	connection.close()!
	session.close()
	assert !os.exists(session.directory)
	if mut reused := unix.connect_stream(session.path) {
		reused.close() or {}
		assert false, 'password endpoint remained available after use'
	}
}

fn test_password_wait_can_be_cancelled_without_writing_a_secret_file() ! {
	mut session := new_remote_prompts('cancel-fixture-secret', true)!
	path := session.directory
	session.close()
	session.close()
	assert !os.exists(path)
	for invalid in ['', 'line\nbreak', 'nul\x00byte'] {
		validate_ssh_password(invalid) or { continue }
		assert false, 'invalid password accepted'
	}
}

fn test_bundled_workbench_can_reply_as_askpass_without_opening_a_window() ! {
	executable := os.getenv('VHTTPD_REMOTE_ASKPASS_TEST_EXECUTABLE')
	if executable == '' { return }
	password := 'installed-fixture $ quote\' space'
	mut session := new_remote_prompts(password, true)!
	defer { session.close() }
	mut child := os.new_process(executable)
	defer { child.close() }
	child.set_args(['fixture password:'])
	child.set_environment(session.environment())
	child.set_redirect_stdio()
	child.run()
	child.wait()
	assert child.code == 0
	assert child.stdout_slurp() == password + '\n'
	assert !child.stderr_slurp().contains(password)
}

fn test_bundled_workbench_host_key_helper_waits_for_confirmation() ! {
	executable := os.getenv('VHTTPD_REMOTE_ASKPASS_TEST_EXECUTABLE')
	if executable == '' { return }
	mut session := new_remote_prompts('', false)!
	defer { session.close() }
	mut child := os.new_process(executable)
	defer { child.close() }
	child.set_args(["The authenticity of host 'fixture' can't be established.\nRSA key fingerprint is: SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "])
	child.set_environment(session.environment())
	child.set_redirect_stdio()
	child.run()
	mut challenge := RemoteHostKey{}
	select {
		key := <-session.challenges { challenge = key }
		5 * time.second { child.signal_kill(); child.wait(); assert false, 'bundled host confirmation missing' }
	}
	session.decisions <- challenge.id
	child.wait()
	assert child.code == 0
	assert child.stdout_slurp() == 'yes\n'
}
