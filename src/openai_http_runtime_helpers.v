module main

import config
import api.openai
import dispatch
import net
import net.http
import veb
import worker

struct OpenAIErrorResponseWriter {}

struct OpenAIResponseWriter {}

struct OpenAIRequestHeaders {}

fn OpenAIResponseWriter.write(mut app App, mut ctx Context, status int, path string, method string, req_id string, trace_id string, start_ms i64, body string, content_type string, headers map[string]string, metadata map[string]string) veb.Result {
	mut response_headers := {
		'content-type': content_type
	}
	for key, value in headers {
		if key != '' && value != '' {
			response_headers[key] = value
		}
	}
	mut event_metadata := {
		'provider': 'openai'
	}
	for key, value in metadata {
		if key != '' && value != '' {
			event_metadata[key] = value
		}
	}
	ctx.set_custom_header('x-request-id', req_id) or {}
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request(method,
		path, path, '', if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } }, req_id,
		trace_id, start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(status,
		response_headers, body), event_metadata), none)
}

fn OpenAIErrorResponseWriter.write(mut app App, mut ctx Context, status int, path string, method string, req_id string, trace_id string, start_ms i64, code string, message string) veb.Result {
	return OpenAIErrorResponseWriter.write_typed(mut app, mut ctx, status, path, method, req_id,
		trace_id, start_ms, code, message, 'invalid_request_error')
}

fn OpenAIErrorResponseWriter.write_typed(mut app App, mut ctx Context, status int, path string, method string, req_id string, trace_id string, start_ms i64, code string, message string, typ string) veb.Result {
	body := openai.OpenAIErrorResponse.body_json(code, message, typ)
	return OpenAIResponseWriter.write(mut app, mut ctx, status, path, method, req_id, trace_id,
		start_ms, body, 'application/json; charset=utf-8', map[string]string{}, map[string]string{})
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
