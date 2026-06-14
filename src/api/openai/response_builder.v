module openai

import x.json2

// ── Completion JSON ──

pub fn completion_json_from_mapping(plan OpenAIResolvedPlan, mapping OpenAIFrameMapping, req_id string, created int) string {
	mut message := map[string]json2.Any{}
	message['role'] = json2.Any('assistant')
	message['content'] = json2.Any(mapping.content)
	if mapping.tool_calls.len > 0 {
		message['tool_calls'] = json2.Any(mapping.tool_calls)
	}
	mut choice := map[string]json2.Any{}
	choice['index'] = json2.Any(0)
	choice['message'] = json2.Any(message)
	choice['finish_reason'] = json2.Any(if mapping.finish_reason != '' {
		mapping.finish_reason
	} else if mapping.tool_calls.len > 0 {
		'tool_calls'
	} else {
		'stop'
	})
	mut root := map[string]json2.Any{}
	root['id'] = json2.Any('chatcmpl-${req_id}')
	root['object'] = json2.Any('chat.completion')
	root['created'] = json2.Any(created)
	root['model'] = json2.Any(plan.model)
	root['choices'] = json2.Any([json2.Any(choice)])
	if mapping.usage.len > 0 {
		root['usage'] = json2.Any(usage_json_obj(mapping.usage))
	}
	return json2.Any(root).json_str()
}

pub fn executor_once_body(plan OpenAIResolvedPlan, raw string, req_id string, created int) string {
	parsed := json2.decode[json2.Any](raw) or {
		return completion_json_from_mapping(plan, OpenAIFrameMapping{
			content: raw
			handled: true
		}, req_id, created)
	}
	root := parsed.as_map()
	if body_any := root['body'] {
		body := body_any.str()
		if body != '' {
			return body
		}
	}
	if _ := root['choices'] {
		return raw
	}
	if _ := root['error'] {
		return raw
	}
	return completion_json_from_mapping(plan, executor_mapping_from_result(raw), req_id, created)
}

pub fn OpenAIResponseBuilder.executor_once_body(plan OpenAIResolvedPlan, raw string, req_id string, created int) string {
	return executor_once_body(plan, raw, req_id, created)
}

pub fn responses_executor_once_body(plan OpenAIResolvedPlan, raw string, req_id string, created int) string {
	parsed := json2.decode[json2.Any](raw) or { return raw }
	root := parsed.as_map()
	if body_any := root['body'] {
		body := body_any.str()
		if body != '' {
			return body
		}
	}
	if (root['object'] or { json2.Any('') }).str() == 'response' {
		return raw
	}
	if _ := root['output'] {
		return raw
	}
	content := (root['content'] or { json2.Any('') }).str()
	text := if content != '' { content } else { raw }
	response_id := if req_id.trim_space() != '' { 'resp_${req_id}' } else { 'resp_vhttpd' }
	mut response := {
		'id':         json2.Any(response_id)
		'object':     json2.Any('response')
		'created_at': json2.Any(created)
		'status':     json2.Any('completed')
		'model':      json2.Any(plan.model)
		'output':     json2.Any([
			json2.Any({
				'id':      json2.Any('msg_${req_id}')
				'type':    json2.Any('message')
				'status':  json2.Any('completed')
				'role':    json2.Any('assistant')
				'content': json2.Any([
					json2.Any({
						'type':        json2.Any('output_text')
						'text':        json2.Any(text)
						'annotations': json2.Any([]json2.Any{})
					}),
				])
			}),
		])
	}
	if usage_any := root['usage'] {
		response['usage'] = usage_any
	}
	return json2.Any(response).json_str()
}

pub fn OpenAIResponseBuilder.responses_executor_once_body(plan OpenAIResolvedPlan, raw string, req_id string, created int) string {
	return responses_executor_once_body(plan, raw, req_id, created)
}

pub fn map_once_response(plan OpenAIResolvedPlan, body string, req_id string, created int) !string {
	if plan.response_codec !in ['ndjson', 'json']
		|| plan.output_protocol != 'openai.chat.completion' {
		return OpenAIResolvedPlan.plan_error('openai_plugin_plan_unsupported_mapper',
			'unsupported mapper ${plan.response_codec} -> ${plan.output_protocol}')
	}
	mut content := ''
	mut tool_calls := []json2.Any{}
	mut usage := map[string]int{}
	if plan.response_codec == 'ndjson' {
		for line in body.split_into_lines() {
			mapping := extract_mapped_row(line)
			content += mapping.content
			merge_tool_calls(mut tool_calls, mapping.tool_calls)
			merge_usage(mut usage, mapping.usage)
		}
	} else {
		mapping := extract_mapped_row(body)
		content = mapping.content
		merge_tool_calls(mut tool_calls, mapping.tool_calls)
		merge_usage(mut usage, mapping.usage)
	}
	mut message := map[string]json2.Any{}
	message['role'] = json2.Any('assistant')
	message['content'] = json2.Any(content)
	if tool_calls.len > 0 {
		message['tool_calls'] = json2.Any(tool_calls)
	}
	mut choice := map[string]json2.Any{}
	choice['index'] = json2.Any(0)
	choice['message'] = json2.Any(message)
	choice['finish_reason'] = json2.Any(if tool_calls.len > 0 { 'tool_calls' } else { 'stop' })
	mut root := map[string]json2.Any{}
	root['id'] = json2.Any('chatcmpl-${req_id}')
	root['object'] = json2.Any('chat.completion')
	root['created'] = json2.Any(created)
	root['model'] = json2.Any(plan.model)
	root['choices'] = json2.Any([json2.Any(choice)])
	if usage.len > 0 {
		root['usage'] = json2.Any(usage_json_obj(usage))
	}
	return json2.Any(root).json_str()
}

pub fn OpenAIResponseBuilder.map_once_response(plan OpenAIResolvedPlan, body string, req_id string, created int) !string {
	return map_once_response(plan, body, req_id, created)
}

// ── Stream Event Formatting ──

pub fn response_stream_event_from_raw(raw string) string {
	parsed := json2.decode[json2.Any](raw) or { return 'data: ${raw}\n\n' }
	root := parsed.as_map()
	event_type := (root['event'] or { root['type'] or { json2.Any('') } }).str()
	if data_any := root['data'] {
		data := if data_any.str() != '' { data_any.str() } else { data_any.json_str() }
		if event_type != '' {
			return 'event: ${event_type}\ndata: ${data}\n\n'
		}
		return 'data: ${data}\n\n'
	}
	if event_type != '' {
		return 'event: ${event_type}\ndata: ${raw}\n\n'
	}
	return 'data: ${raw}\n\n'
}

pub fn OpenAIResponseBuilder.stream_event_from_raw(raw string) string {
	return response_stream_event_from_raw(raw)
}

pub fn response_body_from_completed_event(raw string) string {
	parsed := json2.decode[json2.Any](raw) or { return '' }
	root := parsed.as_map()
	event_type := (root['type'] or { root['event'] or { json2.Any('') } }).str()
	if event_type != 'response.completed' {
		return ''
	}
	response_any := root['response'] or { return '' }
	mut response := response_any.as_map()
	if (response['object'] or { json2.Any('') }).str() == '' {
		response['object'] = json2.Any('response')
	}
	return json2.Any(response).json_str()
}

pub fn OpenAIResponseBuilder.body_from_completed_event(raw string) string {
	return response_body_from_completed_event(raw)
}
