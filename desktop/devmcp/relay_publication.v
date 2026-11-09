module devmcp

import crypto.rand
import host
import net
import net.urllib
import os

// The public HTTPS URL belongs to the chosen Hub. The Agent's only upstream
// is this publication's dedicated, authenticated loopback MCP listener.
pub fn (mut s Service) publish_relay(worker host.Worker, version string, relay host.SharedRelay, public_url string, writable bool) ! {
	if s.remote_hub_id != '' { return error('revoke the current dedicated Hub first') }
	validate_relay_endpoint(relay, public_url)!
	binary := s.selection().binary
	if !os.is_executable(binary) {
		return error('找不到当前环境的 vhttpd 运行包。')
	}
	id := rand.bytes(12)!.hex()
	dir := os.join_path(os.real_path(os.temp_dir()), 'vhttpd-mcp-relay-' + id)
	grant := s.issue_relay(worker, version, writable)!
	s.start_relay_agent(binary, relay, grant.url, dir, id) or {
		s.revoke_relay()
		return err
	}
	s.relay_public_url = public_url
	s.relay_publication_id = id
	s.relay_target_id = relay.id
	s.relay_mode = if writable { 'edit' } else { 'read_only' }
}

fn (mut s Service) start_relay_agent(binary string, relay host.SharedRelay, upstream string, dir string, id string) ! {
	os.mkdir(dir, mode: 0o700)!
	s.relay_agent_dir = dir
	path := os.join_path(dir, 'agent.toml')
	agent := host.shared_relay_toml(relay, relay.relay_id, 'desktop-mcp-' + id)!
	os.write_file(path, 'version = 2
[server]
pid_file = "agent.pid"
' + agent.replace('autostart = false\n', 'autostart = true\n') + '
[adapters.desktop-mcp]
kind = "mcp-upstream"
options.url = "${upstream}"

[[pipelines]]
id = "relay/local-mcp"
ingress = "relay:${relay.relay_id}"
egress = "adapter:desktop-mcp"
')!
	// A listener-less Agent config still gets the runtime's default HTTP
	// listener. Give that listener an isolated loopback port.
	mut reservation := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := reservation.addr()!.port()!
	reservation.close()!
	mut child := os.new_process(os.real_path(binary))
	child.set_work_folder(dir)
	child.set_args(['--config', path, '--host', '127.0.0.1', '--port', port.str()])
	$if windows { child.create_no_window = true }
	child.run()
	s.relay_agent = child
	if !child.is_alive() {
		return error('无法启动 vhttpd Relay Agent。')
	}
}

// Called by Desktop's UI tick. Stop the carrier when its grant expires, and
// revoke the grant when its carrier process exits.
pub fn (mut s Service) poll_relay() bool {
	if isnil(s.relay_agent) || isnil(s.relay) {
		return false
	}
	if s.relay.grant.is_revoked() || !s.relay_agent.is_alive() {
		s.revoke_relay()
		return true
	}
	return false
}

fn validate_relay_endpoint(relay host.SharedRelay, public_url string) ! {
	relay.validate()!
	if !relay.is_native() || !relay.url.starts_with('wss://') || relay.token == '' {
		return error('请选择带 Token 的 vhttpd WSS Relay。')
	}
	endpoint := urllib.parse(public_url) or { return error('请输入有效的公网 HTTPS MCP 地址。') }
	carrier := urllib.parse(relay.url)!
	if endpoint.scheme != 'https' || endpoint.hostname() != carrier.hostname()
		|| public_url.all_after('://').all_before('/').contains('@') || endpoint.force_query
		|| endpoint.raw_query != '' || endpoint.fragment != ''
		|| endpoint.path == '' || public_url.bytes().any(it <= 32 || it == 127) {
		return error('公网 MCP 地址必须使用与 Relay 相同的主机名，并包含 HTTPS 路径。')
	}
}
