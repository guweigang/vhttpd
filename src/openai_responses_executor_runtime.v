module main

import api.openai
import time
import upstream.transport
import veb
import worker
import x.json2

fn OpenAIProxyRuntime.responses_executor_once(mut app App, mut ctx Context, plan openai.OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	resp := app.openai_call_executor_op(plan, 'responses.execute', method, path, req_id, trace_id) or {
		return OpenAIErrorResponseWriter.write(mut app, mut ctx, 502, path, method, req_id,
			trace_id, start_ms, 'openai_executor_failed', err.msg())
	}
	body := openai.OpenAIResponseBuilder.responses_executor_once_body(plan, resp.result, req_id,
		int(time.now().unix()))
	app.openai_store_response_record(plan, body, req_id, trace_id)
	ctx.res.set_status(.ok)
	ctx.set_content_type('application/json; charset=utf-8')
	ctx.set_custom_header('x-request-id', req_id) or {}
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_custom_header('x-vhttpd-openai-backend', plan.backend_name) or {}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
		'status':      '200'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'provider':    'openai'
		'backend':     plan.backend_name
		'executor':    plan.backend.executor
		'endpoint':    'responses'
	})
	return ctx.text(if method.to_upper() == 'HEAD' { '' } else { body })
}

fn OpenAIProxyRuntime.responses_executor_stream(mut app App, mut ctx Context, plan openai.OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	ctx.takeover_conn_reusable()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut client_conn := ctx.conn
	mut headers := {
		'x-request-id':             req_id
		'x-vhttpd-trace-id':        trace_id
		'x-vhttpd-openai-backend':  plan.backend_name
		'x-vhttpd-openai-executor': plan.backend.executor
		'x-accel-buffering':        'no'
	}
	worker.WorkerHttpStreamWriter.write_headers_conn(mut client_conn, 200, 'text/event-stream',
		headers, true) or {}
	mut registry_state := &openai.OpenAIResponsesStreamRegistryState{}
	stream_resp := app.openai_call_executor_stream_op(plan, 'responses.execute', method, path,
		req_id, trace_id, fn [mut client_conn, mut registry_state] (raw string) !bool {
		if registry_state.completed_body == '' {
			registry_state.completed_body =
				openai.OpenAIResponseBuilder.body_from_completed_event(raw)
		}
		worker.WorkerHttpStreamWriter.write_chunk(mut client_conn,
			openai.OpenAIResponseBuilder.stream_event_from_raw(raw))!
		return true
	}) or {
		OpenAIErrorResponseWriter.write_sse(mut client_conn, 'openai_executor_failed', err.msg(),
			'server_error')
		worker.WorkerHttpStreamWriter.write_final_chunk(mut client_conn) or {}
		client_conn.close() or {}
		app.emit('http.request', {
			'method':      method.to_upper()
			'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
			'status':      '502'
			'request_id':  req_id
			'trace_id':    trace_id
			'duration_ms': '${time.now().unix_milli() - start_ms}'
			'provider':    'openai'
			'backend':     plan.backend_name
			'executor':    plan.backend.executor
			'endpoint':    'responses'
		})
		return veb.no_result()
	}
	if !stream_resp.streamed {
		mut wrote_frame := false
		for mapping in openai.OpenAIFrameMapping.executor_stream_mappings(stream_resp.response.result) {
			if mapping.error != '' {
				OpenAIErrorResponseWriter.write_sse(mut client_conn, 'openai_executor_error',
					mapping.error, 'server_error')
				wrote_frame = true
				break
			}
			event := {
				'type':            json2.Any('response.output_text.delta')
				'delta':           json2.Any(mapping.content)
				'sequence_number': json2.Any(1)
			}
			if mapping.content != '' {
				worker.WorkerHttpStreamWriter.write_chunk(mut client_conn,
					openai.OpenAIResponseBuilder.stream_event_from_raw(json2.Any(event).json_str())) or {}
				wrote_frame = true
			}
			if mapping.done {
				registry_state.completed_body = '{"id":"resp_${req_id}","object":"response","status":"completed","model":"${plan.model}"}'
				worker.WorkerHttpStreamWriter.write_chunk(mut client_conn,
					openai.OpenAIResponseBuilder.stream_event_from_raw('{"type":"response.completed","sequence_number":2,"response":${registry_state.completed_body}}')) or {}
				wrote_frame = true
			}
		}
		if !wrote_frame {
			registry_state.completed_body = '{"id":"resp_${req_id}","object":"response","status":"completed","model":"${plan.model}"}'
			worker.WorkerHttpStreamWriter.write_chunk(mut client_conn,
				openai.OpenAIResponseBuilder.stream_event_from_raw('{"type":"response.completed","sequence_number":1,"response":${registry_state.completed_body}}')) or {}
		}
	}
	if registry_state.completed_body != '' {
		app.openai_store_response_record(plan, registry_state.completed_body, req_id, trace_id)
	}
	worker.WorkerHttpStreamWriter.write_final_chunk(mut client_conn) or {}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        transport.WorkerHttpRequestCodec.normalize_path(path)
		'status':      '200'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'provider':    'openai'
		'backend':     plan.backend_name
		'executor':    plan.backend.executor
		'endpoint':    'responses'
	})
	return veb.no_result()
}
