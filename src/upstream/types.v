module upstream

import net
import transport

// OllamaNdjsonMessage represents the "message" field of an Ollama NDJSON row.
pub struct OllamaNdjsonMessage {
pub:
	content string
}

// OllamaNdjsonRow represents a single NDJSON line from the Ollama API.
pub struct OllamaNdjsonRow {
pub:
	message  OllamaNdjsonMessage
	response string
	done     bool
}

// Io bridges transport-level I/O from the main App to upstream sub-module.
pub struct Io {
pub:
	write_sse_message                fn (mut net.TcpConn, transport.WorkerStreamFrame) !             = unsafe { nil }
	write_chunk                      fn (mut net.TcpConn, string) !                                  = unsafe { nil }
	write_http_stream_headers_conn   fn (mut net.TcpConn, int, string, map[string]string, bool) !   = unsafe { nil }
}

// ExecState tracks the lifecycle of a single upstream stream execution.
@[heap]
pub struct ExecState {
pub mut:
	io                  Io
	conn                net.TcpConn
	method              string
	stream_type         string
	mapper              string
	field_path          string
	fallback_field_path string
	sse_event           string
	status_code         int
	content_type        string
	response_headers    map[string]string
	headers_written     bool
	line_buf            string
	token_index         int
}
