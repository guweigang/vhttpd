module devmcp

import host
import json2 as json
import net.http
import time

struct RelayInitialize {
	jsonrpc string
	id      int
	result  RelayInitializeResult
}

struct RelayInitializeResult {
	protocol_version string          @[json: protocolVersion]
	server_info      RelayServerInfo @[json: serverInfo]
}

struct RelayServerInfo {
	name string
}

fn probe_relay_status(reply chan host.DevelopmentReply, status string, url string, token string, grant &host.DevelopmentAccess) {
	mut report := json.decode[map[string]json.Any](status) or {
		reply <- host.DevelopmentReply{ error: true, value: 'relay_status_unavailable' }
		return
	}
	state, code := probe_relay_handshake(url, token)
	report['handshake'] = json.Any(if grant.is_revoked() { 'revoked_during_probe' } else { state })
	report['http_status'] = json.Any(code)
	reply <- host.DevelopmentReply{ value: json.encode(report) }
}

fn probe_relay_handshake(url string, token string) (string, int) {
	mut header := http.new_header()
	header.add(.authorization, 'Bearer ' + token)
	header.add(.content_type, 'application/json')
	header.add(.accept, 'application/json, text/event-stream')
	config := http.FetchConfig{
		url:                  url
		method:               .post
		header:               header
		data:                 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"vhttpd-desktop-probe","version":"1"}}}'
		validate:             true
		allow_redirect:       false
		max_retries:          1
		read_timeout:         5 * time.second
		write_timeout:        5 * time.second
		stop_receiving_limit: 64 * 1024
	}
	response := http.fetch(config) or { return 'unreachable', 0 }
	code := response.status_code
	if code != 200 { return 'http_error', code }
	session := response.header.get_custom('Mcp-Session-Id') or { '' }
	initialized := json.decode[RelayInitialize](response.body) or { return 'invalid_mcp_response', code }
	if initialized.jsonrpc != '2.0' || initialized.id != 1
		|| initialized.result.server_info.name != 'vhttpd-desktop'
		|| initialized.result.protocol_version == '' || session == '' {
		return 'invalid_mcp_response', code
	}
	header.add_custom('Mcp-Session-Id', session) or { return 'invalid_mcp_response', code }
	header.add_custom('MCP-Protocol-Version', initialized.result.protocol_version) or {
		return 'invalid_mcp_response', code
	}
	closed := http.fetch(http.FetchConfig{ ...config, method: .delete, header: header, data: '' }) or {
		return 'ready_session_cleanup_failed', code
	}
	return if closed.status_code in [200, 204] { 'ready' } else { 'ready_session_cleanup_failed' }, code
}
