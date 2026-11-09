module host

import config
import crypto.rand
import crypto.sha1
import encoding.base64
import json2 as json
import net
import net.ssl
import os
import net.urllib
import runtime_plan
import strconv
import time

// Only configuration-selected loopback business listeners reach this transport.
pub struct ProtocolProbeArgs {
pub:
	protocol   string
	listener   string
	path       string
	message    string
	auth_ref string
	tls_trust string = 'system'
	tls_server_name string
	timeout_ms int = 3000
	max_items  int = 4
}

fn (a ProtocolProbeArgs) validate() ! {
	if a.listener.len < 1 || a.listener.len > 256 || a.listener.bytes().any(it <= 32 || it == 127) || a.protocol !in [
		'stream',
		'websocket',
		'mcp',
	] || a.timeout_ms < 100 || a.timeout_ms > 5000
		|| a.max_items < 1 || a.max_items > 8 || a.message.len > 4096
		|| (a.protocol != 'websocket' && a.message != '') {
		return error('invalid_protocol_probe_arguments')
	}
	if a.auth_ref.len > 256 || a.auth_ref.bytes().any(it <= 32 || it >= 127) || a.tls_trust !in ['system', 'listener_certificate'] || a.tls_server_name.len > 253 || a.tls_server_name.bytes().any(it <= 32 || it >= 127 || it == `/` || it == `\\`) {
		return error('invalid_probe_security_arguments')
	}
	decoded := urllib.path_unescape(a.path.all_before('?')) or { return error('invalid_business_probe_path') }
	if a.path.len > 2048 || !a.path.starts_with('/') || a.path.starts_with('//')
		|| a.path.contains('://') || a.path.contains('\\') || a.path.bytes().any(it <= 32 || it == 127)
		|| decoded.starts_with('//') || decoded.contains('\\') || decoded.split('/').any(it in [
		'.',
		'..',
	])
		|| decoded.to_lower().starts_with('/admin') {
		return error('invalid_business_probe_path')
	}
}

pub fn validate_protocol_probe_args(a ProtocolProbeArgs) ! {
	a.validate()!
}

struct ProbeEndpoint {
	host string = '127.0.0.1'
	port int
	secure bool
	tls_name string
	ca_file string
	authorization string
}

fn (e ProbeEndpoint) authority() string {
	return if e.host == '::1' { '[::1]:${e.port}' } else { '127.0.0.1:${e.port}' }
}

fn protocol_probe_endpoint(plan runtime_plan.RuntimePlan, a ProtocolProbeArgs) !ProbeEndpoint {
	a.validate()!
	l := plan.listeners[a.listener] or { return error('unknown_business_listener') }
	if control := plan.control.listener {
		if control.id == a.listener { return error('admin_requests_forbidden') }
	}
	if (l.protocol != 'http' && !(a.protocol == 'websocket' && l.protocol == 'websocket')) || l.port < 1 || l.port > 65535
		|| l.host !in ['', '127.0.0.1', 'localhost', '0.0.0.0', '::1', '::'] {
		return error('http_loopback_listener_required')
	}
	mut authorization := ''
	if a.auth_ref != '' {
		adapter := plan.adapters[a.auth_ref] or { return error('unknown_probe_auth_ref') }
		// Explicit opt-in credential, never Control/Relay/provider credentials. It must
		// belong to an adapter routed from this exact business listener.
		if !plan.pipelines.any(it.ingress.domain == .listener && it.ingress.id == a.listener && it.egress.domain == .adapter && it.egress.id == a.auth_ref) {
			return error('probe_auth_ref_listener_mismatch')
		}
		token := adapter.options.strings['probe_bearer_token']
		if token == '' || token.len > 4096 || token.bytes().any(it <= 32 || it >= 127) {
			return error('probe_bearer_credential_unavailable')
		}
		authorization = 'Authorization: Bearer ' + token + '\r\n'
	}
	if !l.tls.enabled && (a.tls_trust != 'system' || a.tls_server_name != '') {
		return error('probe_tls_listener_required')
	}
	mut ca_file := ''
	if l.tls.enabled && a.tls_trust == 'listener_certificate' {
		ca_file = l.tls.cert
		if a.tls_server_name != '' {
			for cert in l.tls.certificates {
				if a.tls_server_name in cert.hosts { ca_file = cert.cert; break }
			}
		}
		if ca_file == '' { return error('probe_listener_certificate_unavailable') }
	}
	return ProbeEndpoint{ secure: l.tls.enabled, tls_name: a.tls_server_name, ca_file: ca_file, authorization: authorization, host: if l.host in ['::1', '::'] { '::1' } else { '127.0.0.1' }, port: l.port }
}

fn local_protocol_probe(m &Manager, a ProtocolProbeArgs) !string {
	if m.phase != .running { return error('runtime_not_running') }
	endpoint := protocol_probe_endpoint(config.load_runtime_plan_file(m.project.config_path)!, a)!
	return protocol_probe(endpoint, a)
}

struct ProbeHttp {
mut:
	status  int
	headers map[string]string
	body    string
}

// Connect only to the configuration-selected loopback. Name affects SNI/identity,
// never routing or DNS. Certificate verification is mandatory.
fn probe_connect(endpoint ProbeEndpoint, deadline i64) !ProbeSocket {
	// OpenSSL may write a close-notify after a peer has already disconnected.
	// Like the vhttpd server, keep EPIPE a transport error, not process death.
	$if linux { os.signal_ignore(.pipe) }
	mut conn := net.dial_tcp(endpoint.authority()) or { return error('probe_tcp_connect_failed') }
	remaining := deadline - time.ticks()
	if remaining <= 0 { conn.close() or {}; return error('probe_tcp_connect_failed') }
	conn.set_write_timeout(remaining * time.millisecond)
	conn.set_read_timeout(remaining * time.millisecond)
	mut p := ProbeSocket{ tcp: conn, deadline: deadline, secure: endpoint.secure }
	if endpoint.secure {
		ca := if endpoint.ca_file != '' { endpoint.ca_file } else if os.is_file('/etc/ssl/cert.pem') { '/etc/ssl/cert.pem' } else { '' }
		p.tls = ssl.new_ssl_conn(validate: true, verify: ca) or {
			conn.close() or {}; return error('probe_tls_verification_failed')
		}
		p.tls.connect(mut conn, if endpoint.tls_name == '' { endpoint.host } else { endpoint.tls_name }) or {
			p.tls.shutdown() or {}; conn.close() or {}; return error('probe_tls_verification_failed')
		}
	}
	return p
}

fn (mut p ProbeSocket) probe_close() {
	if p.secure && !isnil(p.tls) { p.tls.shutdown() or {} }
	p.tcp.close() or {}
}

fn (mut p ProbeSocket) probe_line() !string {
	mut b := []u8{}
	for b.len < 8192 {
		b << p.read_exact(1)!
		if b.len >= 2 && b[b.len - 2..].bytestr() == '\r\n' { return b[..b.len - 2].bytestr() }
	}
	return error('line_limit')
}

fn (mut p ProbeSocket) probe_headers() !ProbeHttp {
	line := p.probe_line()!
	parts := line.split(' ')
	if parts.len < 2 || parts[0] !in ['HTTP/1.1', 'HTTP/1.0'] { return error('http_status') }
	mut r := ProbeHttp{ status: parts[1].int() }
	mut size := line.len
	for _ in 0 .. 128 {
		h := p.probe_line()!
		size += h.len
		if size > 16384 { return error('headers_limit') }
		if h == '' {
			if r.status in [401, 403] { return error('probe_authentication_rejected_' + r.status.str()) }
			return r
		}
		if !h.contains(':') { return error('http_header') }
		key := h.all_before(':').to_lower()
		if key in r.headers { return error('duplicate_http_header') }
		r.headers[key] = h.all_after(':').trim_space()
	}
	return error('headers_limit')
}

// Bounded entity reader, including chunk framing; timeouts preserve stream evidence.
fn (mut p ProbeSocket) probe_body(r ProbeHttp, streaming bool, items int, rpc_id int) !string {
	chunked := r.headers['transfer-encoding'].to_lower() == 'chunked'
	mut remaining := if 'content-length' in r.headers {
		r.headers['content-length'].int()
	} else {
		-1
	}
	if remaining > 65536 && !streaming { return error('body_limit') }
	mut body := []u8{}
	mut chunk_left := 0
	mut chunk_done := false
	for body.len < 65536 {
		if remaining == 0 { break }
		if chunked && chunk_left == 0 {
			if chunk_done {
				end := p.read_exact(2) or {
					if streaming && body.len > 0 { break }
					return err
				}
				if end.bytestr() != '\r\n' { return error('chunk_end') }
			}
			line := p.probe_line() or {
				if streaming && body.len > 0 { break }
				return err
			}
			chunk_left = int(strconv.parse_uint(line.all_before(';'), 16, 32)!)
			if chunk_left == 0 { break }
			if chunk_left < 0 || chunk_left > 1048576 { return error('chunk_limit') }
			chunk_done = true
		}
		b := p.read_exact(1) or {
			if streaming && body.len > 0 { break }
			if !chunked && remaining < 0 && body.len > 0 { break }
			return err
		}
		body << b
		if chunked { chunk_left-- }
		if remaining > 0 { remaining-- }
		if streaming && b[0] == 10 && body.len >= 2 && (body[body.len - 2] == 10 || (body.len >= 4 && body[body.len - 4..].bytestr() == '\r\n\r\n')) {
			ev := probe_sse_events(body.bytestr())
			if rpc_id > 0 {
				if ev.any(probe_event_id(it) == rpc_id) { break }
				if ev.len >= 8 { return error('mcp_event_limit') }
			} else if ev.len >= items {
				break
			}
		}
	}
	if body.len >= 65536 && !streaming { return error('body_limit') }
	return body.bytestr()
}

fn probe_sse_events(body string) []string {
	mut events := []string{}
	blocks := body.replace('\r\n', '\n').split('\n\n')
	// A trailing incomplete event must not count as delivered.
	for block in blocks[..blocks.len - 1] {
		mut data := []string{}
		for line in block.split('\n') {
			if line.starts_with('data:') { data << line[5..].trim_left(' ') }
		}
		if data.len > 0 { events << data.join('\n') }
	}
	return events
}

fn probe_http(endpoint ProbeEndpoint, a ProtocolProbeArgs, deadline i64, method string, body string, session string) !ProbeHttp {
	mut p := probe_connect(endpoint, deadline)!
	defer { p.probe_close() }
	sid := if session != '' { 'Mcp-Session-Id: ${session}\r\n' } else { '' }
	p.write(('${method} ${a.path} HTTP/1.1\r\nHost: ${endpoint.authority()}\r\nConnection: close\r\nAccept: application/json, text/event-stream\r\nContent-Type: application/json\r\nMCP-Protocol-Version: 2025-03-26\r\n${sid}${endpoint.authorization}Content-Length: ${body.len}\r\n\r\n${body}').bytes())!
	mut r := p.probe_headers()!
	if method == 'DELETE' || r.status == 202 || r.status == 204 { return r }
	streaming := a.protocol == 'stream' || r.headers['content-type'].all_before(';').trim_space() == 'text/event-stream'
	rpc_id := if a.protocol == 'mcp' && body != '' { probe_event_id(body) } else { 0 }
	r.body = p.probe_body(r, streaming, a.max_items, rpc_id)!
	return r
}

fn probe_event_id(text string) int {
	v := json.decode[map[string]json.Any](text) or { return 0 }
	return (v['id'] or { json.Any(0) }).int()
}

fn probe_rpc(r ProbeHttp, id int) !json.Any {
	if r.status != 200 { return error('mcp_http_status') }
	type_ := r.headers['content-type'].all_before(';').trim_space()
	body := if type_ == 'text/event-stream' {
		events := probe_sse_events(r.body).filter(probe_event_id(it) == id)
		if events.len != 1 { return error('mcp_sse_response') }
		events[0]
	} else if type_ == 'application/json' {
		r.body
	} else {
		return error('mcp_content_type')
	}
	v := json.decode[map[string]json.Any](body)!
	if (v['jsonrpc'] or { json.Any('') }).str() != '2.0' || (v['id'] or { json.Any(-1) }).int() != id || 'error' in v {
		return error('mcp_rpc_response')
	}
	return v['result'] or { return error('mcp_result_missing') }
}

fn probe_mcp(endpoint ProbeEndpoint, a ProtocolProbeArgs, deadline i64) !map[string]json.Any {
	r := probe_http(endpoint, a, deadline, 'POST', '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"vhttpd-desktop-probe","version":"1"}}}', '')!
	session := r.headers['mcp-session-id']
	if session.len > 512 || session.bytes().any(it <= 32 || it >= 127) {
		return error('mcp_session_header')
	}
	defer {
		if session != '' {
			probe_http(endpoint, a, time.ticks() + 500, 'DELETE', '', session) or {}
		}
	}
	init := probe_rpc(r, 1)!.as_map()
	version := (init['protocolVersion'] or { json.Any('') }).str()
	if version != '2025-03-26' { return error('mcp_protocol_version') }
	ack := probe_http(endpoint, a, deadline, 'POST', '{"jsonrpc":"2.0","method":"notifications/initialized"}', session)!
	if ack.status !in [200, 202, 204] { return error('mcp_initialized_status') }
	listed := probe_rpc(probe_http(endpoint, a, deadline, 'POST', '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}', session)!, 2)!.as_map()
	tools := listed['tools'] or { return error('mcp_tools_missing') }
	if tools !is []json.Any { return error('mcp_tools_array') }
	mut names := []json.Any{}
	for tool in tools[..if tools.len > a.max_items { a.max_items } else { tools.len }] {
		name := (tool.as_map()['name'] or { json.Any('') }).str()
		if name.len > 256 { return error('mcp_tool_name_limit') }
		names << json.Any(name)
	}
	return {
		'protocol_version': json.Any(version)
		'session_created':  json.Any(session != '')
		'tool_count':       json.Any(tools.len)
		'tools':            json.Any(names)
		'has_more':         json.Any('nextCursor' in listed || tools.len > a.max_items)
	}
}

fn probe_ws(endpoint ProbeEndpoint, a ProtocolProbeArgs, deadline i64) !map[string]json.Any {
	mut p := probe_connect(endpoint, deadline)!
	defer { p.probe_close() }
	key := base64.encode(rand.bytes(16)!)
	p.write(('GET ${a.path} HTTP/1.1\r\nHost: ${endpoint.authority()}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n${endpoint.authorization}\r\n').bytes())!
	r := p.probe_headers()!
	if r.status != 101 || r.headers['upgrade'].to_lower() != 'websocket'
		|| !r.headers['connection'].to_lower().split(',').map(it.trim_space()).contains('upgrade')
		|| r.headers['sec-websocket-accept'] != base64.encode(sha1.sum((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').bytes())) {
		return error('websocket_handshake')
	}
	defer { p.write(masked_probe_frame(8, [u8(3), 232]) or { []u8{} }) or {} }
	if a.message != '' { p.write(masked_probe_frame(1, a.message.bytes())!)! }
	mut messages := []json.Any{}
	mut closed := false
	for _ in 0 .. 16 {
		if messages.len >= a.max_items { break }
		h := p.read_exact(2) or { break }
		if h[0] & 0x70 != 0 || h[1] & 0x80 != 0 { return error('websocket_frame_flags') }
		op := h[0] & 15
		mut size := int(h[1] & 127)
		if size == 127 { return error('websocket_frame_limit') }
		if size == 126 {
			b := p.read_exact(2)!
			size = int(b[0]) * 256 + int(b[1])
		}
		if size > 4096 || (op >= 8 && (size > 125 || h[0] & 128 == 0)) {
			return error('websocket_frame_limit')
		}
		body := p.read_exact(size)!
		if op == 8 {
			closed = true
			break
		}
		if op == 9 {
			p.write(masked_probe_frame(10, body)!)!
			continue
		}
		if op == 10 { continue }
		// Reject fragmentation explicitly rather than reporting partial text as a message.
		if op != 1 || h[0] & 128 == 0 { return error('websocket_text_frame_required') }
		messages << json.Any(body.bytestr())
	}
	return {
		'handshake':     json.Any(true)
		'sent':          json.Any(a.message != '')
		'received_text': json.Any(messages.len > 0)
		'messages':      json.Any(messages)
		'peer_closed':   json.Any(closed)
		'sample_limit':  json.Any(messages.len >= a.max_items)
	}
}

fn protocol_probe(endpoint ProbeEndpoint, a ProtocolProbeArgs) string {
	start := time.ticks()
	deadline := start + a.timeout_ms
	mut result := map[string]json.Any{}
	mut failure := ''
	if a.protocol == 'websocket' {
		result = probe_ws(endpoint, a, deadline) or {
			failure = probe_failure(err.msg(), 'websocket_handshake_or_frame_unavailable')
			map[string]json.Any{}
		}
	} else if a.protocol == 'mcp' {
		result = probe_mcp(endpoint, a, deadline) or {
			failure = probe_failure(err.msg(), 'mcp_initialize_or_tools_list_failed')
			map[string]json.Any{}
		}
	} else {
		r := probe_http(endpoint, a, deadline, 'GET', '', '') or {
			failure = probe_failure(err.msg(), 'http_stream_unavailable')
			ProbeHttp{}
		}
		if failure == '' {
			events := probe_sse_events(r.body)
			result = {
				'status':       json.Any(r.status)
				'content_type': json.Any(r.headers['content-type'].all_before(';'))
				'bytes':        json.Any(r.body.len)
				'events':       json.Any(events.map(json.Any(it)))
				'sample':       json.Any(r.body)
				'sample_limit': json.Any(r.body.len >= 65536 || events.len >= a.max_items)
			}
			if r.status != 200 || (r.headers['content-type'].starts_with('text/event-stream') && events.len == 0) {
				failure = 'http_status_or_no_complete_event'
			}
		}
	}
	mut safe := DevelopmentState{}
	secret := endpoint.authorization.trim_string_left('Authorization: Bearer ').trim_space()
	if endpoint.authorization != '' { safe.secrets['<probe-credential>'] = secret }
	return json.encode(safe.safe_json(json.Any({
		'ok':             json.Any(failure == '')
		'protocol':       json.Any(a.protocol)
		'listener':       json.Any(a.listener)
		'source':         json.Any('business_protocol')
		'address_family': json.Any(if endpoint.host == '::1' { 'ipv6' } else { 'ipv4' })
		'tls': json.Any(endpoint.secure)
		'tls_verified': json.Any(endpoint.secure && failure !in ['probe_tls_verification_failed', 'probe_tcp_connect_failed'])
		'auth_configured': json.Any(endpoint.authorization != '')
		'stage': json.Any(probe_failure_stage(failure))
		'elapsed_ms':     json.Any(time.ticks() - start)
		'failure':        json.Any(failure)
		'result':         json.Any(result)
	})))
}

fn probe_failure(message string, fallback string) string {
	return if message in ['probe_tls_verification_failed', 'probe_tcp_connect_failed', 'probe_authentication_rejected_401', 'probe_authentication_rejected_403'] { message } else { fallback }
}

fn probe_failure_stage(failure string) string {
	return if failure == 'probe_tls_verification_failed' { 'tls' } else if failure == 'probe_tcp_connect_failed' { 'connect' } else if failure.starts_with('probe_authentication_rejected_') { 'authentication' } else { 'protocol' }
}

// Safe configuration inventory; no sockets, paths, certificate bytes or secrets.
fn protocol_probe_options(plan runtime_plan.RuntimePlan, allowed []string) string {
	mut listeners := []json.Any{}
	mut ids := plan.listeners.keys()
	ids.sort()
	for id in ids {
		if id !in allowed { continue }
		a := ProtocolProbeArgs{listener: id, protocol: 'websocket', path: '/'}
		endpoint := protocol_probe_endpoint(plan, a) or { continue }
		l := plan.listeners[id] or { continue }
		mut refs := []string{}
		for adapter_id, adapter in plan.adapters {
			if adapter.options.strings['probe_bearer_token'] != '' && plan.pipelines.any(it.ingress.domain == .listener && it.ingress.id == id && it.egress.domain == .adapter && it.egress.id == adapter_id) { refs << adapter_id }
		}
		refs.sort()
		mut names := []string{}
		for certificate in l.tls.certificates { names << certificate.hosts }
		listeners << json.Any({
			'listener': json.Any(id)
			'protocols': json.Any((if l.protocol == 'websocket' { ['websocket'] } else { ['stream', 'websocket', 'mcp'] }).map(json.Any(it)))
			'address_family': json.Any(if endpoint.host == '::1' { 'ipv6' } else { 'ipv4' })
			'tls': json.Any(endpoint.secure)
			'listener_certificate_available': json.Any(l.tls.cert != '' || l.tls.certificates.len > 0)
			'certificate_hosts': json.Any(names.map(json.Any(it)))
			'auth_refs': json.Any(refs.map(json.Any(it)))
		})
	}
	return json.encode({'source': json.Any('configuration'), 'listeners': json.Any(listeners)})
}
