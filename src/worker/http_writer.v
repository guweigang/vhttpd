module worker

import net
import strings
import upstream.transport
import veb.sse

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

pub fn WorkerHttpStreamWriter.write_headers_conn_with_close[T](mut conn T, status int, content_type string, extra_headers map[string]string, chunked bool, close_conn bool) ! {
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
	conn.write(sb.str().bytes())!
}

pub fn WorkerHttpStreamWriter.write_headers_conn[T](mut conn T, status int, content_type string, extra_headers map[string]string, chunked bool) ! {
	WorkerHttpStreamWriter.write_headers_conn_with_close(mut conn, status, content_type,
		extra_headers, chunked, true)!
}

pub fn WorkerHttpStreamWriter.write_chunk[T](mut conn T, data string) ! {
	if data.len == 0 {
		return
	}
	conn.write('${data.len:x}\r\n'.bytes())!
	conn.write(data.bytes())!
	conn.write('\r\n'.bytes())!
}

pub fn WorkerHttpStreamWriter.write_final_chunk[T](mut conn T) ! {
	conn.write('0\r\n\r\n'.bytes())!
}

fn sse_message(frame transport.WorkerStreamFrame) sse.SSEMessage {
	return sse.SSEMessage{
		id:    frame.sse_id
		event: frame.sse_event
		data:  frame.data
		retry: frame.sse_retry
	}
}

pub fn WorkerHttpStreamWriter.write_sse_message(mut conn net.TcpConn, frame transport.WorkerStreamFrame) ! {
	mut stream := sse.SSEConnection{conn: conn}
	stream.send_message(sse_message(frame))!
}

fn encode_sse_message[T](message T) !string {
	$for method in T.methods {
		$if method.name == 'encode' {
			return message.$method()
		}
	}
	return error('SSE encoding for an arbitrary writer is unavailable in this V toolchain')
}

pub fn WorkerHttpStreamWriter.write_sse_message_to_writer[T](mut conn T, frame transport.WorkerStreamFrame) ! {
	encoded := encode_sse_message(sse_message(frame))!
	conn.write(encoded.bytes())!
}
