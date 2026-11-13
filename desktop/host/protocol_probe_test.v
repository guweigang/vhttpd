module host

import crypto.sha1
import encoding.base64
import json2 as json
import net
import runtime_plan
import time

fn protocol_fixture(mut listener net.TcpListener, mode string, finished chan int) {
	mut deleted := 0
	defer {
		listener.close() or {}
		finished <- deleted
	}
	for attempt in 0 .. if mode == 'mcp' { 4 } else { 1 } {
		mut c := listener.accept() or { return }
		mut p := ProbeSocket{ tcp: c, deadline: time.ticks() + 6000 }
		first := p.probe_line() or {
			c.close() or {}
			return
		}
		mut headers := map[string]string{}
		for _ in 0 .. 128 {
			line := p.probe_line() or { break }
			if line == '' { break }
			headers[line.all_before(':').to_lower()] = line.all_after(':').trim_space()
		}
		address := c.addr() or { panic(err) }
		assert headers['host'] == address.str()
		if headers['content-length'].int() > 0 {
			p.read_exact(headers['content-length'].int()) or {}
		}
		if mode in ['sse', 'partial'] {
			text := if mode == 'partial' {
				'data: first\n\n'
			} else {
				'data: first\r\n\r\ndata: second\n\n'
			}
			c.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n${text.len:x}\r\n${text}\r\n') or {}
			// Keep stream alive beyond the sample count; client must not wait for EOF.
			p.read_exact(1) or {}
		} else if mode in ['ws', 'badws'] {
			key := headers['sec-websocket-key']
			accept := base64.encode(sha1.sum((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').bytes()))
			c.write_string('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${if mode == 'badws' {
				'wrong'
			} else {
				accept
			}}\r\n\r\n') or {}
			if mode == 'ws' {
				h := p.read_exact(2) or {
					c.close() or {}
					return
				}
				assert h[1] & 128 != 0
				mask := p.read_exact(4) or {
					c.close() or {}
					return
				}
				mut text := p.read_exact(int(h[1] & 127)) or {
					c.close() or {}
					return
				}
				for i in 0 .. text.len { text[i] ^= mask[i % 4] }
				// Ping must be answered; then a text frame proves real data exchange.
				c.write([u8(137), 1, 9]) or {}
				mut frame := [u8(129), u8(text.len)]
				frame << text
				c.write(frame) or {}
				p.read_exact(2) or {}
			}
		} else {
			if first.starts_with('DELETE ') {
				deleted++
				c.write_string('HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n') or {}
			} else if headers['mcp-session-id'] == '' {
				body := '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"qa","version":"1"}}}'
				c.write_string('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nMcp-Session-Id: private-session-never-return\r\nContent-Length: ${body.len}\r\n\r\n${body}') or {}
			} else if attempt == 1 {
				c.write_string('HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n') or {}
			} else {
				body := 'data: {"jsonrpc":"2.0","method":"notifications/message","params":{}}\n\ndata: {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"hello","description":"not-returned"}]}}\n\n'
				c.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: ${body.len}\r\n\r\n${body}') or {}
			}
		}
		c.close() or {}
	}
}

fn test_protocol_probe_real_bounded_stream_websocket_and_mcp_session_cleanup() ! {
	for host in ['127.0.0.1', '::1'] {
		for mode in ['sse', 'partial', 'ws', 'badws', 'mcp'] {
			mut listener := net.listen_tcp(if host == '::1' { .ip6 } else { .ip }, if host == '::1' {
				'[::1]:0'
			} else {
				'127.0.0.1:0'
			})!
			port := int(listener.addr()!.port()!)
			done := chan int{cap: 1}
			spawn protocol_fixture(mut listener, mode, done)
			a := ProtocolProbeArgs{
				protocol:   if mode in ['sse', 'partial'] {
					'stream'
				} else if mode in ['ws', 'badws'] {
					'websocket'
				} else {
					'mcp'
				}
				listener:   'web'
				path:       '/probe'
				message:    if mode == 'ws' { 'echo-qa' } else { '' }
				max_items:  if mode == 'sse' {
					2
				} else if mode == 'partial' {
					4
				} else {
					1
				}
				timeout_ms: if mode == 'partial' { 200 } else { 2000 }
			}
			value := protocol_probe(ProbeEndpoint{ host: host, port: port }, a)
			v := json.decode[json.Any](value)!.as_map()
			assert v['address_family']!.str() == if host == '::1' { 'ipv6' } else { 'ipv4' }
			assert v['ok']!.bool() == (mode != 'badws'), value
			if mode == 'sse' {
				assert value.contains('second'), value
				assert v['elapsed_ms']!.i64() < 1800
			}
			if mode == 'partial' {
				assert value.contains('first') && v['elapsed_ms']!.i64() < 1500, value
			}
			if mode == 'ws' {
				assert value.contains('echo-qa'), value
			}
			if mode == 'mcp' {
				assert value.contains('hello'), value
				assert !value.contains('private-session') && !value.contains('not-returned')
			}
			select {
				deleted := <-done {
					if mode == 'mcp' {
						assert deleted == 1
					}
				}
				7 * time.second {
					return error('probe transport not closed')
				}
			}
		}
	}
}

fn test_protocol_probe_rejects_unsafe_paths_and_limits() ! {
	for path in ['https://host/', '//host/', '/admin/config', '/%61dmin/config', '/x/../admin',
		'/x\\admin', '/x\r\nHeader:x'] {
		if _ := (ProtocolProbeArgs{ listener: 'web', protocol: 'stream', path: path }).validate() {
			return error('unsafe path accepted: ' + path)
		}
	}
	for a in [ProtocolProbeArgs{ listener: 'web', protocol: 'ssh', path: '/' },
		ProtocolProbeArgs{ listener: 'web', protocol: 'mcp', path: '/', message: 'write' },
		ProtocolProbeArgs{ listener: 'web', protocol: 'stream', path: '/', timeout_ms: 6000 },
		ProtocolProbeArgs{ listener: 'web', protocol: 'websocket', path: '/', max_items: 100 }] {
		if _ := a.validate() { return error('unsafe arguments accepted') }
	}
	assert probe_sse_events('data: partial').len == 0
	assert probe_sse_events(': ping\n\ndata: a\ndata: b\n\n') == ['a\nb']
}

fn test_protocol_probe_selects_only_configuration_loopback_and_rejects_control() ! {
	a := ProtocolProbeArgs{ listener: 'web', protocol: 'stream', path: '/' }
	for hostname in ['', 'localhost', '127.0.0.1', '0.0.0.0', '::1', '::', '192.0.2.1', 'example.com',
		'::ffff:127.0.0.1'] {
		plan := runtime_plan.RuntimePlan{
			listeners: {
				'web': runtime_plan.ListenerPlan{ id: 'web', protocol: 'http', host: hostname, port: 12345 }
			}
		}
		if hostname in ['192.0.2.1', 'example.com', '::ffff:127.0.0.1'] {
			if _ := protocol_probe_endpoint(plan, a) { return error('non-loopback accepted') }
		} else {
			e := protocol_probe_endpoint(plan, a)!
			assert e.host == if hostname in ['::1', '::'] { '::1' } else { '127.0.0.1' }
			assert e.authority() == if e.host == '::1' { '[::1]:12345' } else { '127.0.0.1:12345' }
		}
	}
	for secure in [false] {
		plan := runtime_plan.RuntimePlan{
			listeners: {
				'web': runtime_plan.ListenerPlan{ id: 'web', protocol: 'http', host: '::1', port: 12345, tls: runtime_plan.TlsPlan{ enabled: secure } }
			}
			control:   runtime_plan.ControlPlan{
				listener: if secure {
					none
				} else {
					runtime_plan.ResourceRef{ id: 'web' }
				}
			}
		}
		if _ := protocol_probe_endpoint(plan, a) { return error('control or TLS accepted') }
	}
}

fn test_probe_security_reference_and_trust_selection() ! {
	plan := runtime_plan.RuntimePlan{
		listeners: {'web': runtime_plan.ListenerPlan{id: 'web', protocol: 'http', host: '::1', port: 443, tls: runtime_plan.TlsPlan{enabled: true, cert: '/configured/public.pem'}}}
		adapters: {'business': runtime_plan.AdapterPlan{id: 'business', options: runtime_plan.PlanOptions{strings: {'probe_bearer_token': 'private-probe-token'}}}, 'other': runtime_plan.AdapterPlan{id: 'other', options: runtime_plan.PlanOptions{strings: {'probe_bearer_token': 'other-private'}}}}
		pipelines: [runtime_plan.PipelinePlan{ingress: runtime_plan.ResourceRef{domain: .listener, id: 'web'}, egress: runtime_plan.ResourceRef{domain: .adapter, id: 'business'}}]
	}
	a := ProtocolProbeArgs{listener: 'web', protocol: 'stream', path: '/', auth_ref: 'business', tls_trust: 'listener_certificate', tls_server_name: 'localhost'}
	assert protocol_probe_options(plan, []string{}).contains('"listeners":[]')
	options := protocol_probe_options(plan, ['web'])
	assert options.contains('business') && options.contains('ipv6')
	assert !options.contains('private-probe-token') && !options.contains('/configured/public.pem')
	e := protocol_probe_endpoint(plan, a)!
	assert e.secure && e.host == '::1' && e.tls_name == 'localhost'
	assert e.ca_file == '/configured/public.pem'
	assert e.authorization == 'Authorization: Bearer private-probe-token\r\n'
	for bad in ['other', 'control', 'missing'] {
		if _ := protocol_probe_endpoint(plan, ProtocolProbeArgs{...a, auth_ref: bad}) { return error('unscoped credential accepted') }
	}
	wrong_domain := runtime_plan.RuntimePlan{...plan, pipelines: [runtime_plan.PipelinePlan{ingress: runtime_plan.ResourceRef{domain: .provider, id: 'web'}, egress: runtime_plan.ResourceRef{domain: .adapter, id: 'business'}}]}
	if _ := protocol_probe_endpoint(wrong_domain, a) { return error('non-listener credential route accepted') }
	for trust in ['insecure', 'false', '/arbitrary/ca.pem'] {
		if _ := protocol_probe_endpoint(plan, ProtocolProbeArgs{...a, tls_trust: trust}) { return error('arbitrary trust accepted') }
	}
}
