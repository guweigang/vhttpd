module main

import config
import api.openai
import net
import net.http
import time
import upstream.transport
import veb
import worker

struct OpenAIErrorResponseWriter {}

struct OpenAIRequestHeaders {}

fn OpenAIErrorResponseWriter.write(mut app App, mut ctx Context, status int, path string, method string, req_id string, trace_id string, start_ms i64, code string, message string) veb.Result {
	return OpenAIErrorResponseWriter.write_typed(mut app, mut ctx, status, path, method, req_id,
		trace_id, start_ms, code, message, 'invalid_request_error')
}

fn OpenAIErrorResponseWriter.write_typed(mut app App, mut ctx Context, status int, path string, method string, req_id string, trace_id string, start_ms i64, code string, message string, typ string) veb.Result {
	body := openai.OpenAIErrorResponse.body_json(code, message, typ)
	ctx.res.set_status(http.status_from_int(status))
	ctx.set_content_type('application/json; charset=utf-8')
	ctx.set_custom_header('x-request-id', req_id) or {}
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
		'status':      '${status}'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'provider':    'openai'
	})
	return ctx.text(body)
}

fn OpenAIErrorResponseWriter.write_conn(mut conn net.TcpConn, status int, headers map[string]string, code string, message string, typ string) {
	worker.WorkerHttpStreamWriter.write_headers_conn(mut conn, status,
		'application/json; charset=utf-8', headers, false) or {}
	conn.write_string(openai.OpenAIErrorResponse.body_json(code, message, typ)) or {}
}

fn OpenAIErrorResponseWriter.write_sse(mut conn net.TcpConn, code string, message string, typ string) {
	worker.WorkerHttpStreamWriter.write_chunk(mut conn, 'data: ${openai.OpenAIErrorResponse.body_json(code,
		message, typ)}\n\n') or {}
	worker.WorkerHttpStreamWriter.write_chunk(mut conn, 'data: [DONE]\n\n') or {}
}

fn OpenAIRequestHeaders.build(mut ctx Context, backend config.OpenAIBackendConfig, req_id string, stream bool, extra map[string]string) http.Header {
	mut header := http.new_header()
	content_type := ctx.req.header.get(.content_type) or { 'application/json' }
	accept := if stream { 'text/event-stream' } else { ctx.req.header.get(.accept) or {
			'application/json'} }
	header.add(.content_type, content_type)
	header.add(.accept, accept)
	header.add_custom('x-request-id', req_id) or {}
	api_key := openai.OpenAIBackendAccess.auth_key(backend)
	if api_key != '' {
		header.add(.authorization, 'Bearer ${api_key}')
	}
	for name, value in extra {
		if name.trim_space() != '' {
			header.add_custom(name, value) or {}
		}
	}
	return header
}
