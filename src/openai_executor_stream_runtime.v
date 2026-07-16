module main

import api.openai
import time
import upstream.transport
import veb
import worker

fn OpenAIProxyRuntime.executor_stream(mut app App, mut ctx Context, plan openai.OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	ctx.takeover_conn_reusable()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut client_conn := ctx.conn
	mut state := &OpenAIMappedStreamProxyState{
		conn:             client_conn
		method:           method
		status_code:      200
		response_headers: {
			'x-request-id':             req_id
			'x-vhttpd-trace-id':        trace_id
			'x-vhttpd-openai-backend':  plan.backend_name
			'x-vhttpd-openai-executor': plan.backend.executor
		}
		model:            plan.model
		request_id:       req_id
		trace_id:         trace_id
		mapper:           'executor'
		response_codec:   plan.response_codec
		output_protocol:  plan.output_protocol
		created:          int(time.now().unix())
	}
	stream_resp := app.openai_call_executor_stream(plan, method, path, req_id, trace_id, fn [mut state, mut client_conn] (raw string) !bool {
		mapping := openai.OpenAIFrameMapping.from_plugin_result(raw)
		if mapping.error != '' {
			state.ensure_headers_written()!
			OpenAIErrorResponseWriter.write_sse(mut client_conn, 'openai_executor_error',
				mapping.error, 'server_error')
			state.done = true
			return false
		}
		if mapping.content != '' || mapping.tool_calls.len > 0 {
			state.ensure_headers_written()!
			worker.WorkerHttpStreamWriter.write_chunk(mut client_conn,
				'data: ${state.chunk_json(mapping)}\n\n')!
		}
		openai.OpenAIUsage.merge(mut state.usage, mapping.usage)
		if mapping.done && !state.done {
			state.ensure_headers_written()!
			state.write_usage_chunk()!
			worker.WorkerHttpStreamWriter.write_chunk(mut client_conn, 'data: [DONE]\n\n')!
			state.done = true
			state.finish()!
			return false
		}
		return true
	}) or {
		if !state.headers_written {
			state.status_code = 502
			state.ensure_headers_written() or {}
			OpenAIErrorResponseWriter.write_sse(mut client_conn, 'openai_executor_failed',
				err.msg(), 'server_error')
			state.done = true
		}
		if state.headers_written {
			state.finish() or {}
		}
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
		})
		return veb.no_result()
	}
	if !stream_resp.streamed {
		for mapping in openai.OpenAIFrameMapping.executor_stream_mappings(stream_resp.response.result) {
			if mapping.error != '' {
				state.ensure_headers_written() or {}
				OpenAIErrorResponseWriter.write_sse(mut client_conn, 'openai_executor_error',
					mapping.error, 'server_error')
				state.done = true
				break
			}
			if mapping.content != '' || mapping.tool_calls.len > 0 {
				state.ensure_headers_written() or {}
				worker.WorkerHttpStreamWriter.write_chunk(mut client_conn,
					'data: ${state.chunk_json(mapping)}\n\n') or {}
			}
			openai.OpenAIUsage.merge(mut state.usage, mapping.usage)
			if mapping.done && !state.done {
				state.ensure_headers_written() or {}
				state.write_usage_chunk() or {}
				worker.WorkerHttpStreamWriter.write_chunk(mut client_conn, 'data: [DONE]\n\n') or {}
				state.done = true
				state.finish() or {}
			}
		}
	}
	if !state.done {
		state.ensure_headers_written() or {}
		state.write_usage_chunk() or {}
		worker.WorkerHttpStreamWriter.write_chunk(mut client_conn, 'data: [DONE]\n\n') or {}
	}
	if state.headers_written {
		state.finish() or {}
	}
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
	})
	return veb.no_result()
}
