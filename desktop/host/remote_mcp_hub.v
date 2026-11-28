module host

import encoding.base64
import json2 as json
import time

pub struct McpHubTarget {
pub:
	worker     ServerWorker
	server     RemoteServer
	project_id string
	runtime_id string
}

pub struct McpHubRequest {
pub:
	id       string
	token    string
	remove   bool
	deadline i64
	reply    chan DevelopmentReply = chan DevelopmentReply{cap: 1}
}

pub struct McpHubPorts {
pub:
	http_port    int
	carrier_port int
}

pub fn (t McpHubTarget) request(id string, token string, remove bool) !McpHubPorts {
	req := McpHubRequest{ id: id, token: token, remove: remove, deadline: time.ticks() + 3500 }
	select {
		t.worker.commands <- ServerCommand{ action: .mcp_hub, server: t.server, project_id: t.project_id, runtime_id: t.runtime_id, mcp_hub: req } {
		}
		else {
			return error('remote_hub_worker_busy')
		}
	}
	select {
		result := <-req.reply {
			if result.error { return error(result.value) }
			return json.decode[McpHubPorts](result.value)!
		}
		12 * time.second {
		}
	}
	return error('remote_hub_worker_timeout')
}

fn (s &ServerSession) mcp_hub(command ServerCommand) !string {
	if !s.state.connected || s.state.root == '' || s.server.id != command.server.id {
		return error('remote_hub_reconnect_selected_server')
	}
	req := command.mcp_hub
	if req.deadline <= time.ticks() { return error('remote_hub_request_expired') }
	if req.id.len != 32 || !req.id.bytes().all(it.is_hex_digit()) {
		return error('invalid_remote_hub_id')
	}
	mut binary := ''
	if !req.remove {
		projects := s.state.projects.filter(it.id == command.project_id)
		if projects.len != 1 || projects[0].runtime_id != command.runtime_id || req.token.len != 64 || !req.token.bytes().all(it.is_hex_digit()) {
			return error('remote_hub_target_unavailable')
		}
		runtime := select_remote_runtime(s.state.runtimes, projects[0].runtime_id)!
		binary = runtime.path + '/vhttpd'
	}
	script := "python3 - <<'VHTTPD_MCP_HUB'\n" + $embed_file('remote_scripts/mcp_hub.py').to_string() +
		'\nmanage(' + json.encode(s.state.root) + ',' + json.encode(req.id) + ',' + json.encode(binary) +
		',' + json.encode(req.token) + ',' + json.encode(base64.encode($embed_file('../../examples/config/mcp-relay-public-v2.toml').to_string().bytes())) +
		',' + if req.remove { 'True)\nVHTTPD_MCP_HUB\n' } else { 'False)\nVHTTPD_MCP_HUB\n' }
	return s.shell(script, 8000)!
}
