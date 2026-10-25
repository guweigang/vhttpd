module host

import crypto.rand
import net.unix
import os
import time
import json2 as json

// Only the endpoint and a random capability reach the SSH environment. The
// password crosses a private Unix socket once and is never written to a file,
// command line, environment variable, profile, diagnostic or browser response.
@[heap]
struct RemoteAskpass {
	directory string
	path string
	capability string
	stop chan bool = chan bool{cap: 1}
	done chan bool = chan bool{cap: 1}
	challenges chan RemoteHostKey = chan RemoteHostKey{cap: 1}
	decisions chan string = chan string{cap: 1}
mut:
	closed bool
}

pub fn validate_ssh_password(password string) ! {
	if password == '' || password.len > 4096 || password.contains('\n') || password.contains('\r') || password.contains('\x00') {
		return error('请输入本次连接的 SSH 密码（不保存到磁盘）。')
	}
}

fn new_remote_prompts(password string, allow_password bool) !&RemoteAskpass {
	if allow_password { validate_ssh_password(password)! }
	// /tmp keeps the path below Darwin's Unix socket length limit, regardless
	// of the user's Application Support or temporary-directory path length.
	directory := os.join_path('/tmp', 'vh-ssh-' + new_remote_id()!)
	os.mkdir(directory, mode: 0o700)!
	mut ready := false
	defer { if !ready { os.rmdir_all(directory) or {} } }
	session := &RemoteAskpass{directory: directory, path: os.join_path(directory, 'auth'), capability: rand.bytes(32)!.hex()}
	mut listener := unix.listen_stream(session.path, unix.ListenOptions{})!
	os.chmod(session.path, 0o600)!
	listener.set_accept_timeout(100 * time.millisecond)
	spawn session.serve(mut listener, password, allow_password)
	ready = true
	return session
}

fn (s &RemoteAskpass) environment() map[string]string {
	mut env := os.environ()
	env['SSH_ASKPASS'] = os.executable()
	env['SSH_ASKPASS_REQUIRE'] = 'force'
	env['DISPLAY'] = 'vhttpd-workbench'
	env['LC_ALL'] = 'C'
	env['VHTTPD_SSH_ASKPASS'] = '1'
	env['VHTTPD_SSH_ASKPASS_SOCKET'] = s.path
	env['VHTTPD_SSH_ASKPASS_CAPABILITY'] = s.capability
	return env
}

struct RemotePromptRequest {
	kind string
	prompt string
}

pub struct RemoteHostKey {
pub:
	id string
	algorithm string
	fingerprint string
	prompt string
}

fn parse_remote_host_key(prompt string) !RemoteHostKey {
	if !prompt.contains('Are you sure you want to continue connecting') { return error('ssh_host_prompt_invalid') }
	for original_line in prompt.split_into_lines() {
		line := original_line.replace(' key fingerprint is: ', ' key fingerprint is ')
		if !line.contains(' key fingerprint is SHA256:') { continue }
		algorithm := line.all_before(' key fingerprint is ').trim_space()
		fingerprint := line.all_after(' key fingerprint is ').trim_space().trim_right('.')
		if algorithm !in ['ED25519', 'ECDSA', 'RSA', 'DSA'] || fingerprint.len > 128 || !fingerprint.all_after('SHA256:').bytes().all(it.is_alnum() || it in [u8(`+`), `/`, `=`]) {
			return error('ssh_host_fingerprint_invalid')
		}
		return RemoteHostKey{id: new_remote_id()!, algorithm: algorithm, fingerprint: fingerprint, prompt: prompt}
	}
	return error('ssh_host_fingerprint_missing')
}

fn (s &RemoteAskpass) serve(mut listener unix.StreamListener, password string, allow_password bool) {
	defer {
		listener.close() or {}
		os.rmdir_all(s.directory) or {}
		s.done <- true
	}
	mut deadline := time.ticks() + 15000
	mut confirmed := false
	for time.ticks() < deadline {
		select { _ := <-s.stop { return } else {} }
		mut connection := listener.accept() or { continue }
		connection.set_read_timeout(500 * time.millisecond)
		connection.set_write_timeout(500 * time.millisecond)
		capability := read_askpass_line(mut connection, 64) or { connection.close() or {}; continue }
		if capability != s.capability { connection.close() or {}; continue }
		raw := read_askpass_line(mut connection, 16384) or { connection.close() or {}; continue }
		request := json.decode[RemotePromptRequest](raw) or { connection.close() or {}; continue }
		if request.kind == 'host_key' && !confirmed {
			challenge := parse_remote_host_key(request.prompt) or { connection.close() or {}; continue }
			s.challenges <- challenge
			confirmation_deadline := time.ticks() + 10 * 60 * 1000
			mut accepted := false
			for time.ticks() < confirmation_deadline {
				select {
					_ := <-s.stop { connection.close() or {}; return }
					id := <-s.decisions { accepted = id == challenge.id; break }
					100 * time.millisecond {}
				}
			}
			connection.write_string(if accepted { 'yes\n' } else { 'no\n' }) or {}
			connection.close() or {}
			if !accepted { return }
			confirmed = true
			deadline = time.ticks() + 15000
			continue
		}
		if request.kind == 'password' && allow_password {
			connection.write_string(password + '\n') or {}
			connection.close() or {}
			return
		}
		connection.close() or {}
	}
}

fn (mut s RemoteAskpass) close() {
	if s.closed { return }
	s.closed = true
	s.stop <- true
	select { _ := <-s.done {} 2 * time.second {} }
}

fn read_askpass_line(mut connection unix.StreamConn, limit int) !string {
	mut bytes := []u8{}
	mut byte := []u8{len: 1}
	for bytes.len <= limit {
		if connection.read(mut byte)! != 1 { return error('ssh_askpass_closed') }
		if byte[0] == `\n` { return bytes.bytestr() }
		bytes << byte[0]
	}
	return error('ssh_askpass_invalid')
}

// Called before normal application startup when OpenSSH executes this same
// bundled binary as its askpass helper. stdout is SSH's private reply pipe.
pub fn run_remote_askpass() ! {
	if os.args.len != 2 { return error('ssh_askpass_prompt_rejected') }
	prompt := os.args.last()
	kind := if prompt.contains('Are you sure you want to continue connecting') && prompt.contains('SHA256:') {
		'host_key'
	} else if os.getenv('SSH_ASKPASS_PROMPT') != 'confirm' && prompt.to_lower().contains('password') {
		'password'
	} else { return error('ssh_askpass_prompt_rejected') }
	path := os.getenv('VHTTPD_SSH_ASKPASS_SOCKET')
	capability := os.getenv('VHTTPD_SSH_ASKPASS_CAPABILITY')
	if path == '' || capability.len != 64 { return error('ssh_askpass_unavailable') }
	mut connection := unix.connect_stream(path)!
	defer { connection.close() or {} }
	connection.set_read_timeout(if kind == 'host_key' { 11 * time.minute } else { 2 * time.second })
	connection.set_write_timeout(2 * time.second)
	connection.write_string(capability + '\n' + json.encode(RemotePromptRequest{kind: kind, prompt: prompt}) + '\n')!
	reply := read_askpass_line(mut connection, 4096)!
	if kind == 'password' { validate_ssh_password(reply)! }
	else if reply !in ['yes', 'no'] { return error('ssh_host_reply_invalid') }
	println(reply)
}
