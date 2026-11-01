module host

import crypto.sha1
import encoding.base64
import net
import time

fn websocket_probe_fixture(mut listener net.TcpListener, requests chan string) {
	mut connection := listener.accept() or { return }
	defer { connection.close() or {} }
	connection.set_read_timeout(3 * time.second)
	mut header := ''
	for header.len < 16384 && !header.ends_with('\r\n\r\n') {
		mut byte := []u8{len: 1}
		if connection.read(mut byte) or { 0 } != 1 { return }
		header += byte.bytestr()
	}
	key := header.all_after('Sec-WebSocket-Key: ').all_before('\r\n')
	accept := base64.encode(sha1.sum((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').bytes()))
	connection.write_string('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n') or { return }
	mut frame := []u8{len: 512}
	n := connection.read(mut frame) or { 0 }
	requests <- header + if n > 0 { '\nOPCODE=' + int(frame[0] & 15).str() } else { '' }
}

fn test_generic_websocket_probe_preserves_query_and_never_sends_native_registration() ! {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { listener.close() or {} }
	port := listener.addr()!.port()!
	requests := chan string{cap: 1}
	spawn websocket_probe_fixture(mut listener, requests)
	result := probe_shared_relay(SharedRelay{ id: 'ab'.repeat(12), protocol: 'websocket', name: 'Application', url: 'ws://127.0.0.1:${port}/ws?serverId=probe&role=client&v=2', token: 'fixture-bearer' })
	assert result.ok && result.stage == 'WebSocket', result.message
	assert result.message.contains('应用协议和业务认证需由应用验证')
	request := <-requests
	assert request.contains('GET /ws?serverId=probe&role=client&v=2 HTTP/1.1')
	assert request.contains('Authorization: Bearer fixture-bearer\r\n')
	assert request.contains('OPCODE=8'), 'Probe must close without native registration or business messages'
}
