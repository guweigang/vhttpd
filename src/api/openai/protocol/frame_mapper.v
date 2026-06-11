module openai

import x.json2

// ── Frame Extraction ──

pub fn extract_mapped_row(line string) OpenAIFrameMapping {
	parsed := json2.decode[json2.Any](line) or { return OpenAIFrameMapping{} }
	root := parsed.as_map()
	done := (root['done'] or { json2.Any(false) }).bool()
	mut tool_calls := []json2.Any{}
	usage := usage_from_map(root)
	if message_any := root['message'] {
		message := message_any.as_map()
		content := (message['content'] or { json2.Any('') }).str()
		if tool_calls_any := message['tool_calls'] {
			tool_calls = tool_calls_any.as_array()
		}
		return OpenAIFrameMapping{
			content:       content
			tool_calls:    tool_calls
			usage:         usage
			done:          done
			handled:       true
			finish_reason: if tool_calls.len > 0 { 'tool_calls' } else { '' }
		}
	}
	if tool_calls_any := root['tool_calls'] {
		tool_calls = tool_calls_any.as_array()
		return OpenAIFrameMapping{
			tool_calls:    tool_calls
			usage:         usage
			done:          done
			handled:       true
			finish_reason: if tool_calls.len > 0 { 'tool_calls' } else { '' }
		}
	}
	if response_any := root['response'] {
		return OpenAIFrameMapping{
			content: response_any.str()
			usage:   usage
			done:    done
			handled: true
		}
	}
	if content_any := root['content'] {
		return OpenAIFrameMapping{
			content: content_any.str()
			usage:   usage
			done:    done
			handled: true
		}
	}
	return OpenAIFrameMapping{
		usage:   usage
		done:    done
		handled: true
	}
}

// ── Tool Call Merging ──

pub fn tool_call_index(call map[string]json2.Any, fallback int) int {
	index_any := call['index'] or { return fallback }
	return index_any.int()
}

pub fn merge_tool_call(existing map[string]json2.Any, incoming map[string]json2.Any) map[string]json2.Any {
	mut merged := existing.clone()
	for key in ['id', 'type', 'index'] {
		if value := incoming[key] {
			if key == 'index' || value.str() != '' {
				merged[key] = value
			}
		}
	}
	if incoming_fn_any := incoming['function'] {
		incoming_fn := incoming_fn_any.as_map()
		mut fn_obj := if existing_fn_any := merged['function'] {
			existing_fn_any.as_map()
		} else {
			map[string]json2.Any{}
		}
		if name_any := incoming_fn['name'] {
			name := name_any.str()
			if name != '' {
				fn_obj['name'] = json2.Any(name)
			}
		}
		if args_any := incoming_fn['arguments'] {
			args := args_any.str()
			if args != '' {
				prev := (fn_obj['arguments'] or { json2.Any('') }).str()
				fn_obj['arguments'] = json2.Any(prev + args)
			}
		}
		merged['function'] = json2.Any(fn_obj)
	}
	return merged
}

pub fn merge_tool_calls(mut acc []json2.Any, calls []json2.Any) {
	for call_any in calls {
		call := call_any.as_map()
		index := tool_call_index(call, acc.len)
		mut found := -1
		for i, existing_any in acc {
			existing := existing_any.as_map()
			if tool_call_index(existing, i) == index {
				found = i
				break
			}
		}
		if found < 0 {
			acc << json2.Any(call)
			continue
		}
		acc[found] = json2.Any(merge_tool_call(acc[found].as_map(), call))
	}
}

// ── Plugin / Executor Frame Mapping ──

pub fn plugin_map_frame_result(raw string) OpenAIFrameMapping {
	if OpenAIPluginPlanResult.not_handled(raw) {
		return OpenAIFrameMapping{}
	}
	parsed := json2.decode[json2.Any](raw) or {
		return OpenAIFrameMapping{
			handled: true
			error:   'invalid mapper response'
		}
	}
	root := parsed.as_map()
	if error_any := root['error'] {
		error_obj := error_any.as_map()
		if error_obj.len > 0 {
			message := (error_obj['message'] or { json2.Any('mapper error') }).str()
			return OpenAIFrameMapping{
				done:    true
				handled: true
				error:   message
			}
		}
		err_msg := error_any.str()
		return OpenAIFrameMapping{
			done:    true
			handled: true
			error:   if err_msg == '' { 'mapper error' } else { err_msg }
		}
	}
	content := (root['content'] or { json2.Any('') }).str()
	mut tool_calls := []json2.Any{}
	if tool_calls_any := root['tool_calls'] {
		tool_calls = tool_calls_any.as_array()
	}
	usage := usage_from_map(root)
	done := (root['done'] or { json2.Any(false) }).bool()
	return OpenAIFrameMapping{
		content:       content
		tool_calls:    tool_calls
		usage:         usage
		done:          done
		handled:       true
		finish_reason: json_string_field(root, 'finish_reason', if tool_calls.len > 0 {
			'tool_calls'
		} else {
			''
		})
	}
}

pub fn executor_mapping_from_result(raw string) OpenAIFrameMapping {
	parsed := json2.decode[json2.Any](raw) or {
		return OpenAIFrameMapping{
			content: raw
			handled: true
		}
	}
	root := parsed.as_map()
	if root.len == 0 {
		return OpenAIFrameMapping{
			content: raw
			handled: true
		}
	}
	return plugin_map_frame_result(raw)
}

pub fn executor_stream_mappings(raw string) []OpenAIFrameMapping {
	parsed := json2.decode[json2.Any](raw) or {
		return [
			OpenAIFrameMapping{
				content: raw
				done:    true
				handled: true
			},
		]
	}
	root := parsed.as_map()
	if frames_any := root['frames'] {
		mut mappings := []OpenAIFrameMapping{}
		for frame in frames_any.as_array() {
			mappings << plugin_map_frame_result(frame.json_str())
		}
		return mappings
	}
	return [executor_mapping_from_result(raw)]
}
