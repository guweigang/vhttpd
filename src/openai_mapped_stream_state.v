module main

import api.openai
import json
import net
import x.json2
import worker

@[heap]
struct OpenAIMappedStreamProxyState {
mut:
	app              &App = unsafe { nil }
	conn             net.TcpConn
	method           string
	status_code      int
	response_headers map[string]string
	headers_written  bool
	line_buffer      string
	model            string
	request_id       string
	trace_id         string
	mapper           string
	response_codec   string
	output_protocol  string
	created          int
	done             bool
	mapper_error     string
	error_body       string
	usage            map[string]int
	chunk_decoder    openai.ChunkDecodeState
	final_written    bool
}

fn (mut state OpenAIMappedStreamProxyState) finish() ! {
	if state.headers_written && !state.final_written {
		worker.WorkerHttpStreamWriter.write_final_chunk(mut state.conn)!
		state.final_written = true
	}
}

fn (mut state OpenAIMappedStreamProxyState) ensure_headers_written() ! {
	if state.headers_written {
		return
	}
	mut headers := state.response_headers.clone()
	headers['x-accel-buffering'] = 'no'
	worker.WorkerHttpStreamWriter.write_headers_conn_with_close(mut state.conn, state.status_code,
		'text/event-stream', headers, true, false)!
	state.headers_written = true
}

fn (state OpenAIMappedStreamProxyState) chunk_json(mapping openai.OpenAIFrameMapping) string {
	mut delta := map[string]json2.Any{}
	if mapping.content != '' {
		delta['content'] = json2.Any(mapping.content)
	}
	if mapping.tool_calls.len > 0 {
		delta['tool_calls'] = json2.Any(mapping.tool_calls)
	}
	mut choice := map[string]json2.Any{}
	choice['index'] = json2.Any(0)
	choice['delta'] = json2.Any(delta)
	if mapping.finish_reason != '' {
		choice['finish_reason'] = json2.Any(mapping.finish_reason)
	}
	mut root := map[string]json2.Any{}
	root['id'] = json2.Any('chatcmpl-${state.request_id}')
	root['object'] = json2.Any('chat.completion.chunk')
	root['created'] = json2.Any(state.created)
	root['model'] = json2.Any(state.model)
	root['choices'] = json2.Any([json2.Any(choice)])
	return json2.Any(root).json_str()
}

fn (state OpenAIMappedStreamProxyState) usage_chunk_json() string {
	mut root := map[string]json2.Any{}
	root['id'] = json2.Any('chatcmpl-${state.request_id}')
	root['object'] = json2.Any('chat.completion.chunk')
	root['created'] = json2.Any(state.created)
	root['model'] = json2.Any(state.model)
	root['choices'] = json2.Any([]json2.Any{})
	root['usage'] = json2.Any(openai.OpenAIUsage.json_obj(state.usage))
	return json2.Any(root).json_str()
}

fn (mut state OpenAIMappedStreamProxyState) write_usage_chunk() ! {
	if state.usage.len == 0 {
		return
	}
	state.ensure_headers_written()!
	worker.WorkerHttpStreamWriter.write_chunk(mut state.conn,
		'data: ${state.usage_chunk_json()}\n\n')!
}

fn (mut app App) openai_plugin_map_frame(plan openai.OpenAIResolvedPlan, frame string, req_id string, trace_id string) !openai.OpenAIFrameMapping {
	resp := app.openai_call_plugin('chat.map_frame', json.encode(openai.OpenAIPluginMapFramePayload{
		model:           plan.model
		frame:           frame
		response_codec:  plan.response_codec
		output_protocol: plan.output_protocol
		request_id:      req_id
		trace_id:        trace_id
	}), req_id, trace_id, {
		'model':  plan.model
		'mapper': 'plugin'
	})!
	return openai.OpenAIFrameMapping.from_plugin_result(resp.result)
}

fn (mut state OpenAIMappedStreamProxyState) map_line_with_plugin(line string) openai.OpenAIFrameMapping {
	mut app := unsafe { &App(state.app) }
	return app.openai_plugin_map_frame(openai.OpenAIResolvedPlan{
		model:           state.model
		response_codec:  state.response_codec
		output_protocol: state.output_protocol
	}, line, state.request_id, state.trace_id) or {
		return openai.OpenAIFrameMapping{
			done:    true
			handled: true
			error:   err.msg()
		}
	}
}

fn (mut state OpenAIMappedStreamProxyState) write_mapped_line(line string) ! {
	trimmed := line.trim_space()
	if trimmed == '' {
		return
	}
	mapping := if state.mapper == 'plugin' {
		plugin_mapping := state.map_line_with_plugin(trimmed)
		if plugin_mapping.error != '' {
			state.mapper_error = plugin_mapping.error
		}
		if plugin_mapping.handled {
			plugin_mapping
		} else {
			openai.OpenAIFrameMapping.from_ndjson_row(trimmed)
		}
	} else {
		openai.OpenAIFrameMapping.from_ndjson_row(trimmed)
	}
	if mapping.error != '' {
		state.mapper_error = mapping.error
		state.ensure_headers_written()!
		OpenAIErrorResponseWriter.write_sse(mut state.conn, 'mapper_error', mapping.error,
			'server_error')
		state.done = true
		state.finish()!
		return
	}
	if mapping.content != '' || mapping.tool_calls.len > 0 {
		state.ensure_headers_written()!
		worker.WorkerHttpStreamWriter.write_chunk(mut state.conn,
			'data: ${state.chunk_json(mapping)}\n\n')!
	}
	openai.OpenAIUsage.merge(mut state.usage, mapping.usage)
	if mapping.done && !state.done {
		state.ensure_headers_written()!
		state.write_usage_chunk()!
		worker.WorkerHttpStreamWriter.write_chunk(mut state.conn, 'data: [DONE]\n\n')!
		state.done = true
		state.finish()!
	}
}

fn (mut state OpenAIMappedStreamProxyState) reset_for_plan(plan openai.OpenAIResolvedPlan) {
	state.status_code = 200
	state.response_headers['x-vhttpd-openai-backend'] = plan.backend_name
	state.line_buffer = ''
	state.model = plan.model
	state.mapper = plan.mapper
	state.response_codec = plan.response_codec
	state.output_protocol = plan.output_protocol
	state.done = false
	state.mapper_error = ''
	state.error_body = ''
	state.usage = map[string]int{}
	state.final_written = false
}
