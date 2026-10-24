module host

import crypto.rand
import crypto.sha1
import encoding.base64
import net
import net.ssl
import net.urllib
import os
import relay
import time

pub struct RelayProbeResult {
pub:
	ok         bool
	stage      string
	message    string
	elapsed_ms i64
}

struct ProbeSocket {
mut:
	tcp      &net.TcpConn = unsafe { nil }
	tls      &ssl.SSLConn = unsafe { nil }
	secure   bool
	deadline i64
}

fn (mut p ProbeSocket) read_exact(size int) ![]u8 {
	mut data := []u8{len: size}
	mut pos := 0
	for pos < size {
		remaining := p.deadline - time.ticks()
		if remaining <= 0 { return error('timeout') }
		p.tcp.set_read_timeout(remaining * time.millisecond)
		if p.secure { p.tls.set_read_timeout(remaining * time.millisecond) }
		mut chunk := []u8{len: size - pos}
		n := if p.secure { p.tls.read(mut chunk)! } else { p.tcp.read(mut chunk)! }
		if n <= 0 { return error('closed') }
		copy(mut data[pos..], chunk[..n])
		pos += n
	}
	return data
}

fn (mut p ProbeSocket) write(data []u8) ! {
	if p.secure { p.tls.write(data)! } else { p.tcp.write(data)! }
}

fn masked_probe_frame(op u8, data []u8) ![]u8 {
	if data.len > 65535 { return error('frame too large') }
	mask := rand.bytes(4)!
	mut result := [u8(0x80) | op]
	if data.len < 126 {
		result << u8(data.len) | 0x80
	} else {
		result << [u8(0xfe), u8(data.len >> 8), u8(data.len & 255)]
	}
	result << mask
	for i, b in data { result << b ^ mask[i % 4] }
	return result
}

struct ProbeProgress {
mut:
	stage string
}

pub fn probe_shared_relay(r SharedRelay) RelayProbeResult {
	start := time.ticks()
	r.validate() or { return RelayProbeResult{ stage: '地址', message: err.msg() } }
	mut progress := ProbeProgress{ stage: '网络 / DNS' }
	probe_shared_relay_session(r, mut progress) or {
		// Never surface transport/server errors: those can contain credentials.
		return RelayProbeResult{
			stage:      progress.stage
			elapsed_ms: time.ticks() - start
			message:    match progress.stage {
				'TLS' { 'TLS 校验或握手失败，请检查证书、域名和系统时间。' }
				'WebSocket' { 'WebSocket 升级失败，请检查服务地址和路径。' }
				'Relay 认证' {
					'Relay 认证未通过、协议不匹配或等待超时，请检查 Relay ID、Token 和远端状态；旧版服务可能尚不支持安全探测。'
				}
				else { '无法连接远端，请检查网络、域名与端口。' }
			}
		}
	}
	return RelayProbeResult{ ok: true, stage: 'Relay 认证', message: '测试通过：WebSocket 与 Relay 认证握手完成；测试会话已断开，不代表项目已连接。', elapsed_ms: time.ticks() - start }
}

fn probe_shared_relay_session(r SharedRelay, mut progress ProbeProgress) ! {
	u := urllib.parse(r.url)!
	secure := u.scheme == 'wss'
	port := if u.port() != '' {
		u.port()
	} else if secure {
		'443'
	} else {
		'80'
	}
	authority_host := if u.hostname().contains(':') { '[${u.hostname()}]' } else { u.hostname() }
	mut tcp := net.dial_tcp('${authority_host}:${port}')!
	defer { tcp.close() or {} }
	tcp.set_write_timeout(3 * time.second)
	tcp.set_read_timeout(3 * time.second)
	mut p := ProbeSocket{ tcp: tcp, secure: secure, deadline: time.ticks() + 6000 }
	if secure {
		progress.stage = 'TLS'
		// Use the OS-provided CA bundle rather than development/Homebrew paths.
		ca := if os.is_file('/etc/ssl/cert.pem') { '/etc/ssl/cert.pem' } else { '' }
		p.tls = ssl.new_ssl_conn(validate: true, verify: ca)!
		defer { p.tls.shutdown() or {} }
		p.tls.connect(mut tcp, u.hostname())!
	}
	progress.stage = 'WebSocket'
	key := base64.encode(rand.bytes(16)!)
	path := if u.escaped_path() == '' { '/' } else { u.escaped_path() }
	p.write(('GET ${path} HTTP/1.1\r\nHost: ${authority_host}:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n').bytes())!
	mut header := []u8{}
	for header.len < 16384 {
		header << p.read_exact(1)!
		if header.len >= 4 && header[header.len - 4..].bytestr() == '\r\n\r\n' { break }
	}
	if !header.bytestr().ends_with('\r\n\r\n') { return error('oversized header') }
	lines := header.bytestr().split('\r\n')
	if lines.len < 2 || !lines[0].starts_with('HTTP/1.1 101 ') { return error('upgrade') }
	mut headers := map[string]string{}
	for line in lines[1..] {
		if line.contains(':') {
			headers[line.all_before(':').to_lower()] = line.all_after(':').trim_space()
		}
	}
	expected := base64.encode(sha1.sum((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').bytes()))
	if headers['sec-websocket-accept'] != expected || headers['upgrade'].to_lower() != 'websocket' || !headers['connection'].to_lower().split(',').map(it.trim_space()).contains('upgrade') {
		return error('upgrade')
	}
	defer { p.write(masked_probe_frame(8, [u8(3), 232]) or { []u8{} }) or {} }
	progress.stage = 'Relay 认证'
	id := 'workbench-test-' + rand.bytes(12)!.hex()
	registration := relay.registration_hello_frame(relay.RegistrationRequest{ node_id: id, relay_id: r.relay_id, mode: .agent, carrier: 'websocket', token: r.token, trace_id: id, max_channels: 1 })!
	hello := relay.WireFrame{ ...registration, kind: .ping, metadata: {
		...registration.metadata
		'purpose': 'connection-test-v1'
	} }
	p.write(masked_probe_frame(1, relay.encode_frame(hello)!.bytes())!)!
	for _ in 0 .. 8 {
		h := p.read_exact(2)!
		if h[0] & 0x80 == 0 || h[0] & 0x70 != 0 || h[1] & 0x80 != 0 {
			return error('invalid frame')
		}
		mut size := int(h[1] & 0x7f)
		if size == 127 { return error('oversized frame') }
		if size == 126 {
			n := p.read_exact(2)!
			size = int(n[0]) * 256 + int(n[1])
		}
		body := p.read_exact(size)!
		op := h[0] & 15
		if op == 9 && size <= 125 {
			p.write(masked_probe_frame(10, body)!)!
			continue
		}
		if op != 1 { return error('unexpected frame') }
		ack := relay.decode_frame(body.bytestr())!
		if ack.kind != .pong || ack.metadata['purpose'] != 'connection-test-v1' || ack.metadata['node_id'] != id || ack.metadata['relay_id'] != r.relay_id || ack.trace_id != id {
			return error('registration rejected')
		}
		return
	}
	return error('timeout')
}
