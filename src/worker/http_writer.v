module worker

import net
import strings
import upstream.transport

pub struct WorkerHttpStreamWriter {}

pub fn WorkerHttpStreamWriter.status_reason_phrase(status int) string {
	return match status {
		200 { 'OK' }
		201 { 'Created' }
		202 { 'Accepted' }
		204 { 'No Content' }
		301 { 'Moved Permanently' }
		302 { 'Found' }
		304 { 'Not Modified' }
		400 { 'Bad Request' }
		401 { 'Unauthorized' }
		403 { 'Forbidden' }
		404 { 'Not Found' }
		405 { 'Method Not Allowed' }
		408 { 'Request Timeout' }
		409 { 'Conflict' }
		429 { 'Too Many Requests' }
		500 { 'Internal Server Error' }
		502 { 'Bad Gateway' }
		503 { 'Service Unavailable' }
		504 { 'Gateway Timeout' }
		else { 'OK' }
	}
}

pub fn WorkerHttpStreamWriter.write_headers_conn_with_close(mut conn net.TcpConn, status int, content_type string, extra_headers map[string]string, chunked bool, close_conn bool) ! {
	mut code := status
	if code <= 0 {
		code = 200
	}
	mut sb := strings.new_builder(512)
	sb.write_string('HTTP/1.1 ${code} ${WorkerHttpStreamWriter.status_reason_phrase(code)}\r\n')
	sb.write_string('Server: vhttpd\r\n')
	if close_conn {
		sb.write_string('Connection: close\r\n')
	}
	if chunked {
		sb.write_string('Transfer-Encoding: chunked\r\n')
	}
	if content_type != '' {
		sb.write_string('Content-Type: ${content_type}\r\n')
	}
	for name, value in extra_headers {
		lower := name.to_lower()
		if lower == 'content-type' || lower == 'content-length' || lower == 'transfer-encoding'
			|| lower == 'connection' || lower == 'server' {
			continue
		}
		sb.write_string('${name}: ${value}\r\n')
	}
	sb.write_string('\r\n')
	conn.write_string(sb.str())!
}

pub fn WorkerHttpStreamWriter.write_headers_conn(mut conn net.TcpConn, status int, content_type string, extra_headers map[string]string, chunked bool) ! {
	WorkerHttpStreamWriter.write_headers_conn_with_close(mut conn, status, content_type,
		extra_headers, chunked, true)!
}

pub fn WorkerHttpStreamWriter.write_chunk(mut conn net.TcpConn, data string) ! {
	if data.len == 0 {
		return
	}
	conn.write_string('${data.len:x}\r\n')!
	conn.write_string(data)!
	conn.write_string('\r\n')!
}

pub fn WorkerHttpStreamWriter.write_final_chunk(mut conn net.TcpConn) ! {
	conn.write_string('0\r\n\r\n')!
}

pub fn WorkerHttpStreamWriter.write_sse_message(mut conn net.TcpConn, frame transport.WorkerStreamFrame) ! {
	mut sb := strings.new_builder(256)
	if frame.sse_id != '' {
		sb.write_string('id: ${frame.sse_id}\n')
	}
	if frame.sse_event != '' {
		sb.write_string('event: ${frame.sse_event}\n')
	}
	if frame.data != '' {
		sb.write_string('data: ${frame.data}\n')
	}
	if frame.sse_retry != 0 {
		sb.write_string('retry: ${frame.sse_retry}\n')
	}
	sb.write_string('\n')
	conn.write_string(sb.str())!
}
