module main

import api.openai
import time
import upstream.transport
import veb
import worker

// Streaming callbacks and batched executor results share one terminal owner.
fn (mut state OpenAIMappedStreamProxyState) write_executor_mapping(mapping openai.OpenAIFrameMapping) !bool {
	if state.done { return false }
	if mapping.error != '' {
		state.done = true
		state.ensure_headers_written()!
		OpenAIErrorResponseWriter.write_sse(mut state.conn, 'openai_executor_error', mapping.error, 'server_error')
		return false
	}
	if mapping.done { state.done = true }
	if mapping.content != '' || mapping.tool_calls.len > 0 {
		state.ensure_headers_written()!
		worker.WorkerHttpStreamWriter.write_chunk(mut state.conn, 'data: ${state.chunk_json(mapping)}\n\n')!
	}
	openai.OpenAIUsage.merge(mut state.usage, mapping.usage)
	if mapping.done {
		state.ensure_headers_written()!
		state.write_usage_chunk()!
		worker.WorkerHttpStreamWriter.write_chunk(mut state.conn, 'data: [DONE]\n\n')!
		state.finish()!
		return false
	}
	return true
}

fn OpenAIProxyRuntime.executor_stream(mut app App, mut ctx Context, plan openai.OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	// veb retains socket ownership in reusable mode, including failure paths.
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
	stream_resp := app.openai_call_executor_stream(plan, method, path, req_id, trace_id, fn [mut state] (raw string) !bool {
		return state.write_executor_mapping(openai.OpenAIFrameMapping.from_plugin_result(raw))!
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
		ctx.set_header(.connection, 'close')
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
			keep_streaming := state.write_executor_mapping(mapping) or {
				state.done = true
				break
			}
			if !keep_streaming { break }
		}
	}
	if !state.done {
		state.done = true
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
