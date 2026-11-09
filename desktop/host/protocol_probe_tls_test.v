module host

import json2 as json
import net
import net.ssl
import os
import time

fn secure_probe_fixture(mut listener ssl.SSLListener, done chan int) {
	mut received := 0
	defer { listener.shutdown() or {}; done <- received }
	for _ in 0 .. 5 {
		mut conn := listener.accept() or { continue }
		conn.set_read_timeout(2 * time.second)
		mut header := ''
		for header.len < 16384 && !header.ends_with('\r\n\r\n') {
			mut b := []u8{len: 1}
			if conn.read(mut b) or { 0 } != 1 { break }
			header += b.bytestr()
		}
		if header.ends_with('\r\n\r\n') {
			received++
			auth := header.contains('Authorization: Bearer private-probe-token\r\n')
			body := if header.starts_with('GET /echo ') { 'private-probe-token' } else { 'data: secure-event\n\n' }
			kind := if header.starts_with('GET /echo ') { 'text/plain' } else { 'text/event-stream' }
			conn.write('HTTP/1.1 ${if auth { '200 OK' } else { '401 Unauthorized' }}\r\nContent-Type: ${kind}\r\nContent-Length: ${body.len}\r\nConnection: close\r\n\r\n${body}'.bytes()) or {}
		}
		conn.shutdown() or {}
	}
}

fn test_native_tls_authentication_trust_identity_and_redaction() ! {
	root := os.join_path(os.temp_dir(), 'native-secure-probe-${os.getpid()}-${time.ticks()}')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	cert := os.join_path(root, 'cert.pem')
	key := os.join_path(root, 'key.pem')
	r := os.execute("openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1' -keyout '${key}' -out '${cert}'")
	assert r.exit_code == 0
	for host in ['127.0.0.1', '::1'] {
		family := if host == '::1' { net.AddrFamily.ip6 } else { net.AddrFamily.ip }
		mut free := net.listen_tcp(family, if host == '::1' { '[::1]:0' } else { '127.0.0.1:0' })!
		addr := free.addr()!
		free.close()!
		mut server := ssl.new_ssl_listener(addr.str(), ssl.SSLConnectConfig{cert: cert, cert_key: key}, ssl.SSLListenerOptions{family: family})!
		done := chan int{cap: 1}
		spawn secure_probe_fixture(mut server, done)
		base := ProbeEndpoint{host: host, port: int(addr.port()!), secure: true, tls_name: 'localhost', ca_file: cert, authorization: 'Authorization: Bearer private-probe-token\r\n'}
		a := ProtocolProbeArgs{listener: 'secure', protocol: 'stream', path: '/probe', timeout_ms: 2000, max_items: 1}
		for i in 0 .. 5 {
			endpoint := match i {
				1 { ProbeEndpoint{...base, authorization: ''} }
				2 { ProbeEndpoint{...base, tls_name: 'wrong.invalid'} }
				3 { ProbeEndpoint{...base, ca_file: ''} }
				else { base }
			}
			value := protocol_probe(endpoint, if i == 4 { ProtocolProbeArgs{...a, path: '/echo'} } else { a })
			result := json.decode[map[string]json.Any](value)!
			assert !value.contains('private-probe-token')
			expected := if i == 1 { 'probe_authentication_rejected_401' } else if i in [2, 3] { 'probe_tls_verification_failed' } else { '' }
			assert result['failure']!.str() == expected, value
			assert result['ok']!.bool() == (expected == ''), value
			if i == 0 {
				data := result['result']!.as_map()
				events := data['events']!.as_array()
				assert events[0].str() == 'secure-event'
			}
		}
		select {
			count := <-done { assert count == 3 }
			5 * time.second { return error('TLS fixture did not close') }
		}
	}
}
