module worker

import net
import time

fn test_http_writer_headers_and_chunks_use_the_original_socket() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(address.str()) or { panic(err) }
	defer { peer.close() or {} }
	peer.set_read_timeout(time.second)
	mut conn := listener.accept() or { panic(err) }
	defer { conn.close() or {} }
	WorkerHttpStreamWriter.write_headers_conn(mut conn, 200, 'text/plain', {}, true) or { panic(err) }
	WorkerHttpStreamWriter.write_chunk(mut conn, 'hello') or { panic(err) }
	WorkerHttpStreamWriter.write_final_chunk(mut conn) or { panic(err) }
	mut wire := ''
	mut buffer := []u8{len: 4096}
	for !wire.ends_with('0\r\n\r\n') {
		n := peer.read(mut buffer) or { panic(err) }
		assert n > 0
		wire += buffer[..n].bytestr()
	}
	assert wire == 'HTTP/1.1 200 OK\r\nServer: vhttpd\r\nConnection: close\r\nTransfer-Encoding: chunked\r\nContent-Type: text/plain\r\n\r\n5\r\nhello\r\n0\r\n\r\n'
	assert net.shutdown(conn.sock.handle, how: .write) == 0
	WorkerHttpStreamWriter.write_headers_conn(mut conn, 502, 'text/plain', {}, false) or { return }
	assert false, 'closed socket writes must propagate an error'
}
