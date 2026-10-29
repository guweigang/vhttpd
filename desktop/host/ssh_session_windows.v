module host

import sync

// References cross the two worker channels; passwords remain only in the
// authenticated broker closure. Nothing in this registry is serialized.
@[heap]
struct WindowsCredentialStore {
mut:
	mu       sync.Mutex
	sessions map[string]WindowsSshSession
}

struct WindowsSshSession {
	server RemoteServer
	broker &RemoteAskpass
}

const windows_ssh_credentials = &WindowsCredentialStore{}

fn register_windows_session(server RemoteServer, broker &RemoteAskpass) !string {
	id := 'windows-ssh:' + new_remote_id()!
	mut store := windows_ssh_credentials
	store.mu.@lock()
	defer { store.mu.unlock() }
	store.sessions[id] = WindowsSshSession{ server: server, broker: broker }
	return id
}

fn revoke_windows_session(id string) {
	mut store := windows_ssh_credentials
	store.mu.@lock()
	defer { store.mu.unlock() }
	store.sessions.delete(id)
}

fn windows_session(id string) !WindowsSshSession {
	mut store := windows_ssh_credentials
	store.mu.@lock()
	defer { store.mu.unlock() }
	return store.sessions[id] or { return error('服务器会话已断开，请重新连接。') }
}

fn windows_session_alive(id string) bool {
	windows_session(id) or { return false }
	return true
}

fn windows_session_environment(id string, profile RemoteProfile) !map[string]string {
	session := windows_session(id)!
	server := session.server
	if server.ssh_host != profile.ssh_host || server.ssh_user != profile.ssh_user || server.ssh_port != profile.ssh_port || server.auth_method != profile.auth_method || server.identity_file != profile.identity_file {
		return error('实例与服务器认证会话不匹配，请重新连接。')
	}
	return session.broker.environment()
}

fn windows_auth_options(server RemoteServer) []string {
	mut args := ['-o', 'BatchMode=no', '-o', 'StrictHostKeyChecking=yes', '-o', 'ControlMaster=no',
		'-o', 'ControlPath=none', '-o', 'ForwardAgent=no', '-o', 'ConnectTimeout=8']
	if server.auth_method == 'password' {
		args << ['-o', 'PreferredAuthentications=password', '-o', 'PasswordAuthentication=yes',
			'-o', 'PubkeyAuthentication=no', '-o', 'KbdInteractiveAuthentication=no', '-o',
			'NumberOfPasswordPrompts=1']
	} else {
		args << ['-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no']
		if server.identity_file != '' { args << ['-i', server.identity_file] }
	}
	return args
}

fn (s &ServerSession) windows_scp(args []string, limit i64) !string {
	session := windows_session(s.windows_ticket)!
	mut client_args := ['-S', s.ssh_executable]
	client_args << args
	return s.job.command_with_environment(s.scp_executable, client_args, limit, session.broker.environment())
}

// Called only after the initial SSH process emits its authenticated marker.
fn (s &ServerSession) windows_ready() bool {
	return s.ready_output.replace('\r\n','\n').contains('VHTTPD_SSH_READY\n')
}
