module host

import os
import time

fn test_host_registration_is_idempotent_and_never_overwrites_endpoint() ! {
	before := os.getenv('VHTTPD_DESKTOP_DATA_DIR')
	root := os.join_path(os.temp_dir(), 'mcp-registry-' + new_remote_id()!)
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', root, true)
	defer {
		os.setenv('VHTTPD_DESKTOP_DATA_DIR', before, true)
		os.rmdir_all(root) or {}
	}
	candidate := RemoteServer{ name: 'QA', ssh_host: '127.0.0.1', ssh_user: 'fixture', ssh_port: 49284 }
	first := register_mcp_host(candidate)!
	assert first.id.len == 24
	assert register_mcp_host(candidate)! == first
	assert load_remote_servers()!.len == 1
	register_mcp_host(RemoteServer{ ...candidate, name: 'replacement' }) or {
		assert err.msg().contains('already_registered')
		assert load_remote_servers()![0] == first
		return
	}
	assert false
}

fn test_registration_rejects_options_and_control_characters() {
	for candidate in [
		RemoteServer{ name: 'QA', ssh_host: '-oProxyCommand=bad', ssh_port: 22 },
		RemoteServer{ name: 'bad\nname', ssh_host: 'localhost', ssh_port: 22 },
		RemoteServer{ name: 'QA', ssh_host: 'localhost', ssh_port: 0 },
	] {
		mut failed := false
		validate_mcp_host_registration(candidate) or { failed = true }
		assert failed
	}
}

fn test_disconnect_cannot_abandon_pending_remote_operation() {
	mut s := ServerSession{ state: ServerSnapshot{ busy: true } }
	request := McpLifecycleRequest{ tool: 'host_disconnect', deadline: time.now().unix() + 30 }
	s.mcp_registry_request(request) or {
		assert err.msg().contains('busy')
		return
	}
	assert false
}
