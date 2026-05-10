module main

import json
import net
import net.http
import os
import time
import veb
import x.json2

const openai_response_registry_ttl = 24 * time.hour
const openai_stream_done_fetch_error = 'openai_stream_done'

struct OpenAIModelObject {
	id       string
	object   string = 'model'
	created  int
	owned_by string = 'vhttpd'
}

struct OpenAIModelsResponse {
	object string = 'list'
	data   []OpenAIModelObject
}

struct OpenAIErrorBody {
	message string
	typ     string @[json: 'type']
	code    string
}

struct OpenAIErrorResponse {
	error OpenAIErrorBody
}

struct OpenAIResolvedRoute {
	route_name     string
	model          string
	backend_name   string
	upstream_model string
	backend        OpenAIBackendConfig
}

struct OpenAIUpstreamPlan {
	backend         string
	method          string
	path            string
	body            string
	upstream_model  string @[json: 'upstream_model']
	stream_mode     string @[json: 'stream_mode']
	response_codec  string @[json: 'response_codec']
	output_protocol string @[json: 'output_protocol']
	mapper          string
	headers         map[string]string
}

struct OpenAIResolvedPlan {
	backend_name    string
	backend         OpenAIBackendConfig
	method          string
	path            string
	body            string
	model           string
	stream_mode     string
	response_codec  string
	output_protocol string
	mapper          string
	headers         map[string]string
}

struct OpenAIPluginPlanResult {
	handled bool
	plan    OpenAIResolvedPlan
}

struct OpenAIPluginModelsResult {
	handled bool
	models  []string
}

struct OpenAIResponseRecord {
	id              string
	backend_name    string
	backend_kind    string
	executor        string
	model           string
	status          string
	created_at_unix i64
	updated_at_unix i64
	request_id      string
	trace_id        string
	body            string
}

@[heap]
struct OpenAIResponsesStreamRegistryState {
mut:
	completed_body string
}

struct OpenAIPluginChatPayload {
	method     string
	path       string
	model      string
	stream     bool
	body       string
	base_path  string @[json: 'base_path']
	request_id string @[json: 'request_id']
	trace_id   string @[json: 'trace_id']
}

struct OpenAIPluginResponsesPayload {
	method     string
	path       string
	model      string
	stream     bool
	body       string
	base_path  string @[json: 'base_path']
	request_id string @[json: 'request_id']
	trace_id   string @[json: 'trace_id']
}

struct OpenAIPluginModelsPayload {
	method     string
	path       string
	base_path  string @[json: 'base_path']
	request_id string @[json: 'request_id']
	trace_id   string @[json: 'trace_id']
}

struct OpenAIPluginFallbackPayload {
	method         string
	path           string
	model          string
	stream         bool
	body           string
	base_path      string @[json: 'base_path']
	failed_backend string @[json: 'failed_backend']
	status_code    int    @[json: 'status_code']
	error_code     string @[json: 'error_code']
	error_message  string @[json: 'error_message']
	request_id     string @[json: 'request_id']
	trace_id       string @[json: 'trace_id']
}

struct OpenAIExecutorPayload {
	method          string
	path            string
	model           string
	stream          bool
	body            string
	backend         string
	request_id      string @[json: 'request_id']
	trace_id        string @[json: 'trace_id']
	response_codec  string @[json: 'response_codec']
	output_protocol string @[json: 'output_protocol']
}

struct OpenAIPluginMapFramePayload {
	model           string
	frame           string
	response_codec  string @[json: 'response_codec']
	output_protocol string @[json: 'output_protocol']
	request_id      string @[json: 'request_id']
	trace_id        string @[json: 'trace_id']
}

struct OpenAIChatStreamDelta {
	content string
}

struct OpenAIChatStreamChoice {
	index int
	delta OpenAIChatStreamDelta
}

struct OpenAIChatStreamChunk {
	id      string
	object  string = 'chat.completion.chunk'
	created int
	model   string
	choices []OpenAIChatStreamChoice
}

struct OpenAIChatMessage {
	role    string
	content string
}

struct OpenAIChatCompletionChoice {
	index         int
	message       OpenAIChatMessage
	finish_reason string @[json: 'finish_reason']
}

struct OpenAIChatCompletionResponse {
	id      string
	object  string = 'chat.completion'
	created int
	model   string
	choices []OpenAIChatCompletionChoice
}

struct OpenAIFrameMapping {
	content       string
	tool_calls    []json2.Any
	usage         map[string]int
	done          bool
	handled       bool
	error         string
	finish_reason string
}

struct OpenAIChunkDecodeState {
mut:
	mode            string = 'unknown'
	buffer          string
	remaining       int
	need_chunk_crlf bool
	done            bool
}

fn openai_hex_chunk_size(raw string) ?int {
	hex_part := raw.all_before(';').trim_space()
	if hex_part == '' {
		return none
	}
	mut size := 0
	for ch in hex_part {
		mut value := -1
		if ch >= `0` && ch <= `9` {
			value = int(ch - `0`)
		} else if ch >= `a` && ch <= `f` {
			value = 10 + int(ch - `a`)
		} else if ch >= `A` && ch <= `F` {
			value = 10 + int(ch - `A`)
		} else {
			return none
		}
		size = (size * 16) + value
	}
	return size
}

fn openai_decode_progress_chunk(mut decoder OpenAIChunkDecodeState, chunk []u8) string {
	if chunk.len == 0 || decoder.done {
		return ''
	}
	incoming := chunk.bytestr()
	if decoder.mode == 'plain' {
		return incoming
	}
	decoder.buffer += incoming
	if decoder.mode == 'unknown' {
		if decoder.buffer.contains('\r\n') {
			first_line := decoder.buffer.all_before('\r\n')
			_ := openai_hex_chunk_size(first_line) or {
				decoder.mode = 'plain'
				out := decoder.buffer
				decoder.buffer = ''
				return out
			}
			decoder.mode = 'chunked'
		} else if decoder.buffer.contains('\n') || decoder.buffer.len > 64 {
			decoder.mode = 'plain'
			out := decoder.buffer
			decoder.buffer = ''
			return out
		} else {
			return ''
		}
	}
	mut out := ''
	for decoder.mode == 'chunked' && decoder.buffer.len > 0 && !decoder.done {
		if decoder.need_chunk_crlf {
			if decoder.buffer.len < 2 {
				break
			}
			if decoder.buffer.starts_with('\r\n') {
				decoder.buffer = decoder.buffer[2..]
			} else if decoder.buffer.starts_with('\n') {
				decoder.buffer = decoder.buffer[1..]
			}
			decoder.need_chunk_crlf = false
		}
		if decoder.remaining == 0 {
			if !decoder.buffer.contains('\r\n') {
				break
			}
			line := decoder.buffer.all_before('\r\n')
			decoder.buffer = decoder.buffer.all_after('\r\n')
			size := openai_hex_chunk_size(line) or {
				decoder.mode = 'plain'
				out += decoder.buffer
				decoder.buffer = ''
				break
			}
			if size == 0 {
				decoder.done = true
				decoder.buffer = ''
				break
			}
			decoder.remaining = size
		}
		if decoder.remaining > 0 {
			take := if decoder.buffer.len < decoder.remaining {
				decoder.buffer.len
			} else {
				decoder.remaining
			}
			out += decoder.buffer[..take]
			decoder.buffer = decoder.buffer[take..]
			decoder.remaining -= take
			if decoder.remaining == 0 {
				decoder.need_chunk_crlf = true
			}
		}
	}
	return out
}

@[heap]
struct OpenAIStreamProxyState {
mut:
	conn             net.TcpConn
	method           string
	status_code      int
	content_type     string
	response_headers map[string]string
	headers_written  bool
	error_body       string
	chunk_decoder    OpenAIChunkDecodeState
	done             bool
	done_probe       string
	final_written    bool
}

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
	chunk_decoder    OpenAIChunkDecodeState
	final_written    bool
}

fn normalize_openai_base_path(raw string) string {
	mut base := normalize_path(raw.trim_space())
	for base.len > 1 && base.ends_with('/') {
		base = base[..base.len - 1]
	}
	return base
}

fn openai_relative_path(target string, base_path string) ?string {
	request_path, _ := normalize_request_target(target)
	path := normalize_path(request_path)
	base := normalize_openai_base_path(base_path)
	if path == base {
		return ''
	}
	prefix := '${base}/'
	if !path.starts_with(prefix) {
		return none
	}
	return '/' + path[prefix.len..]
}

fn openai_relative_target(target string, base_path string) ?string {
	request_path, query := normalize_request_target(target)
	path := normalize_path(request_path)
	base := normalize_openai_base_path(base_path)
	mut relative := ''
	if path == base {
		relative = ''
	} else {
		prefix := '${base}/'
		if !path.starts_with(prefix) {
			return none
		}
		relative = '/' + path[prefix.len..]
	}
	if query == '' {
		return relative
	}
	return '${relative}?${query}'
}

fn openai_response_content_type(header http.Header, fallback string) string {
	return header.get(.content_type) or { fallback }
}

fn openai_is_stream_request(body string) bool {
	parsed := json2.decode[json2.Any](body) or { return false }
	root := parsed.as_map()
	stream_any := root['stream'] or { return false }
	return stream_any.bool()
}

fn openai_is_stream_target(target string) bool {
	_, query := normalize_request_target(target)
	if query == '' {
		return false
	}
	params := parse_query_map(query)
	stream := params['stream'] or { return false }
	return stream.to_lower() in ['1', 'true', 'yes']
}

fn openai_request_model(body string) string {
	parsed := json2.decode[json2.Any](body) or { return '' }
	root := parsed.as_map()
	return (root['model'] or { json2.Any('') }).str()
}

fn openai_response_id_from_body(body string) string {
	parsed := json2.decode[json2.Any](body) or { return '' }
	root := parsed.as_map()
	if (root['object'] or { json2.Any('') }).str() != 'response' {
		return ''
	}
	return (root['id'] or { json2.Any('') }).str().trim_space()
}

fn openai_response_status_from_body(body string) string {
	parsed := json2.decode[json2.Any](body) or { return '' }
	root := parsed.as_map()
	return (root['status'] or { json2.Any('') }).str()
}

fn openai_response_id_from_relative(relative string) string {
	path := normalize_path(relative.all_before('?'))
	prefix := '/responses/'
	if !path.starts_with(prefix) {
		return ''
	}
	rest := path[prefix.len..]
	if rest.trim_space() == '' {
		return ''
	}
	return rest.split('/')[0].trim_space()
}

fn openai_response_registry_record(plan OpenAIResolvedPlan, response_id string, body string, req_id string, trace_id string) OpenAIResponseRecord {
	now := time.now().unix()
	status := openai_response_status_from_body(body)
	return OpenAIResponseRecord{
		id:              response_id
		backend_name:    plan.backend_name
		backend_kind:    plan.backend.kind
		executor:        plan.backend.executor
		model:           plan.model
		status:          if status == '' { 'completed' } else { status }
		created_at_unix: now
		updated_at_unix: now
		request_id:      req_id
		trace_id:        trace_id
		body:            body
	}
}

fn (mut app App) openai_store_response_record(plan OpenAIResolvedPlan, body string, req_id string, trace_id string) string {
	response_id := openai_response_id_from_body(body)
	if response_id == '' {
		return ''
	}
	record := openai_response_registry_record(plan, response_id, body, req_id, trace_id)
	app.openai_responses.set_with_ttl(response_id, record, openai_response_registry_ttl) or {}
	return response_id
}

fn openai_replace_model_in_body(body string, upstream_model string) string {
	if upstream_model.trim_space() == '' {
		return body
	}
	parsed := json2.decode[json2.Any](body) or { return body }
	mut root := parsed.as_map()
	root['model'] = json2.Any(upstream_model)
	return json2.Any(root).json_str()
}

fn openai_route_models(route OpenAIRouteConfig, route_name string) []string {
	mut models := []string{}
	for raw in route.models {
		model := raw.trim_space()
		if model != '' && model !in models {
			models << model
		}
	}
	if route.model.trim_space() != '' && route.model !in models {
		models << route.model.trim_space()
	}
	if models.len == 0 && route_name.trim_space() != '' {
		models << route_name.trim_space()
	}
	return models
}

fn (app &App) openai_models() []string {
	mut models := []string{}
	for name, route in app.openai_routes {
		for model in openai_route_models(route, name) {
			if model !in models {
				models << model
			}
		}
	}
	models.sort()
	return models
}

fn (app &App) openai_resolve_route(model string) !OpenAIResolvedRoute {
	requested := model.trim_space()
	if requested != '' {
		for name, route in app.openai_routes {
			if requested in openai_route_models(route, name) {
				backend_name := if route.backend.trim_space() != '' {
					route.backend.trim_space()
				} else {
					app.openai_default_backend.trim_space()
				}
				if backend_name == '' {
					return error('missing backend for model ${requested}')
				}
				backend := app.openai_backends[backend_name] or {
					return error('unknown backend ${backend_name}')
				}
				upstream_model := if route.upstream_model.trim_space() != '' {
					route.upstream_model.trim_space()
				} else {
					requested
				}
				return OpenAIResolvedRoute{
					route_name:     name
					model:          requested
					backend_name:   backend_name
					upstream_model: upstream_model
					backend:        backend
				}
			}
		}
	}
	backend_name := app.openai_default_backend.trim_space()
	if backend_name == '' {
		return error('no matching route for model ${requested}')
	}
	backend := app.openai_backends[backend_name] or {
		return error('unknown backend ${backend_name}')
	}
	return OpenAIResolvedRoute{
		model:          requested
		backend_name:   backend_name
		upstream_model: requested
		backend:        backend
	}
}

fn openai_builtin_plan_from_route_for_endpoint_method(route OpenAIResolvedRoute, body string, upstream_path string, output_protocol string, method string) OpenAIResolvedPlan {
	return OpenAIResolvedPlan{
		backend_name:    route.backend_name
		backend:         route.backend
		method:          method.to_upper()
		path:            upstream_path
		body:            openai_replace_model_in_body(body, route.upstream_model)
		model:           route.model
		stream_mode:     'passthrough'
		response_codec:  'sse'
		output_protocol: output_protocol
		mapper:          'builtin'
		headers:         map[string]string{}
	}
}

fn openai_builtin_plan_from_route_for_endpoint(route OpenAIResolvedRoute, body string, upstream_path string, output_protocol string) OpenAIResolvedPlan {
	return openai_builtin_plan_from_route_for_endpoint_method(route, body, upstream_path,
		output_protocol, 'POST')
}

fn openai_builtin_plan_from_route(route OpenAIResolvedRoute, body string) OpenAIResolvedPlan {
	return openai_builtin_plan_from_route_for_endpoint(route, body, '/chat/completions',
		'openai.chat.completion')
}

fn openai_json_string_field(obj map[string]json2.Any, key string, default_val string) string {
	value := obj[key] or { return default_val }
	text := value.str()
	if text == '' {
		return default_val
	}
	return text
}

fn openai_json_string_map_field(obj map[string]json2.Any, key string) map[string]string {
	mut out := map[string]string{}
	value := obj[key] or { return out }
	for name, item in value.as_map() {
		out[name] = item.str()
	}
	return out
}

fn openai_plan_error(code string, message string) IError {
	return error('${code}:${message}')
}

fn openai_plan_error_code(err_msg string) string {
	if err_msg.starts_with('openai_plugin_plan_') && err_msg.contains(':') {
		return err_msg.all_before(':')
	}
	if err_msg.starts_with('openai_plugin_') && err_msg.contains(':') {
		return err_msg.all_before(':')
	}
	if err_msg.starts_with('unknown backend ') {
		return 'openai_plugin_plan_unknown_backend'
	}
	return 'model_not_found'
}

fn openai_plan_error_message(err_msg string) string {
	if (err_msg.starts_with('openai_plugin_plan_') || err_msg.starts_with('openai_plugin_'))
		&& err_msg.contains(':') {
		return err_msg.all_after(':')
	}
	return err_msg
}

fn openai_validate_plan_method(raw string) !string {
	method := raw.trim_space().to_upper()
	if method == '' {
		return 'POST'
	}
	if method in ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'] {
		return method
	}
	return openai_plan_error('openai_plugin_plan_invalid_method', 'unsupported upstream method ${method}')
}

fn openai_validate_plan_path(raw string) !string {
	path := raw.trim_space()
	if path == '' {
		return '/chat/completions'
	}
	if !path.starts_with('/') {
		return openai_plan_error('openai_plugin_plan_invalid_path', 'upstream path must start with /')
	}
	if path.contains('\r') || path.contains('\n') {
		return openai_plan_error('openai_plugin_plan_invalid_path', 'upstream path must not contain newlines')
	}
	return path
}

fn openai_validate_stream_mode(raw string) !string {
	mode := raw.trim_space()
	if mode == '' {
		return 'passthrough'
	}
	if mode in ['passthrough', 'mapped', 'executor'] {
		return mode
	}
	return openai_plan_error('openai_plugin_plan_unsupported_stream_mode', 'unsupported stream_mode ${mode}')
}

fn openai_validate_response_codec(raw string, stream_mode string) !string {
	codec := raw.trim_space()
	if codec == '' {
		return if stream_mode == 'mapped' { 'ndjson' } else { 'sse' }
	}
	if codec in ['sse', 'json', 'ndjson', 'text'] {
		return codec
	}
	return openai_plan_error('openai_plugin_plan_unsupported_response_codec', 'unsupported response_codec ${codec}')
}

fn openai_validate_output_protocol(raw string, stream_mode string) !string {
	protocol := raw.trim_space()
	if protocol == '' {
		return 'openai.chat.completion'
	}
	if stream_mode == 'mapped' && protocol != 'openai.chat.completion' {
		return openai_plan_error('openai_plugin_plan_unsupported_output_protocol', 'unsupported output_protocol ${protocol}')
	}
	return protocol
}

fn openai_validate_mapper(raw string) !string {
	mapper := raw.trim_space()
	if mapper == '' {
		return 'builtin'
	}
	if mapper in ['builtin', 'plugin'] {
		return mapper
	}
	return openai_plan_error('openai_plugin_plan_unsupported_mapper', 'unsupported mapper ${mapper}')
}

fn openai_sanitize_plan_headers(headers map[string]string) map[string]string {
	mut out := map[string]string{}
	for name, value in headers {
		lower := name.trim_space().to_lower()
		if lower == ''
			|| lower in ['connection', 'content-length', 'transfer-encoding', 'host', 'server', 'upgrade', 'proxy-connection', 'keep-alive', 'te', 'trailer'] {
			continue
		}
		if lower.contains('\r') || lower.contains('\n') || value.contains('\r')
			|| value.contains('\n') {
			continue
		}
		out[name] = value
	}
	return out
}

fn openai_plugin_not_handled(raw string) bool {
	parsed := json2.decode[json2.Any](raw) or { return false }
	root := parsed.as_map()
	for key in ['not_handled', 'notHandled'] {
		value := root[key] or { continue }
		if value.bool() {
			return true
		}
	}
	return false
}

fn openai_upstream_plan_from_plugin_json_with_defaults(raw string, default_path string, default_output_protocol string) !OpenAIUpstreamPlan {
	parsed := json2.decode[json2.Any](raw)!
	mut root := parsed.as_map()
	if plan_any := root['plan'] {
		root = plan_any.as_map()
	}
	body := if body_any := root['body'] { body_any.str() } else { '' }
	return OpenAIUpstreamPlan{
		backend:         openai_json_string_field(root, 'backend', '')
		method:          openai_json_string_field(root, 'method', 'POST')
		path:            openai_json_string_field(root, 'path', default_path)
		body:            body
		upstream_model:  openai_json_string_field(root, 'upstream_model', '')
		stream_mode:     openai_json_string_field(root, 'stream_mode', 'passthrough')
		response_codec:  openai_json_string_field(root, 'response_codec', '')
		output_protocol: openai_json_string_field(root, 'output_protocol', default_output_protocol)
		mapper:          openai_json_string_field(root, 'mapper', '')
		headers:         openai_json_string_map_field(root, 'headers')
	}
}

fn openai_upstream_plan_from_plugin_json(raw string) !OpenAIUpstreamPlan {
	return openai_upstream_plan_from_plugin_json_with_defaults(raw, '/chat/completions',
		'openai.chat.completion')
}

fn openai_models_from_plugin_json(raw string) ![]string {
	parsed := json2.decode[json2.Any](raw)!
	root := parsed.as_map()
	mut models := []string{}
	if models_any := root['models'] {
		for item in models_any.as_array() {
			model := item.str().trim_space()
			if model != '' && model !in models {
				models << model
			}
		}
	}
	if data_any := root['data'] {
		for item in data_any.as_array() {
			row := item.as_map()
			model := (row['id'] or { json2.Any('') }).str().trim_space()
			if model != '' && model !in models {
				models << model
			}
		}
	}
	models.sort()
	return models
}

fn (mut app App) openai_call_plugin(op string, payload string, req_id string, trace_id string, metadata map[string]string) !PluginCallResponse {
	plugin_name := app.openai_plugin.trim_space()
	if plugin_name == '' {
		return error('openai_plugin_not_configured')
	}
	return app.call_plugin(PluginCallRequest{
		plugin:     plugin_name
		capability: 'openai'
		op:         op
		request_id: req_id
		trace_id:   trace_id
		payload:    payload
		metadata:   metadata
	})
}

fn (mut app App) openai_plugin_models(method string, path string, req_id string, trace_id string) !OpenAIPluginModelsResult {
	resp := app.openai_call_plugin('models', json.encode(OpenAIPluginModelsPayload{
		method:     method.to_upper()
		path:       path
		base_path:  app.openai_base_path
		request_id: req_id
		trace_id:   trace_id
	}), req_id, trace_id, map[string]string{})!
	if openai_plugin_not_handled(resp.result) {
		return OpenAIPluginModelsResult{}
	}
	return OpenAIPluginModelsResult{
		handled: true
		models:  openai_models_from_plugin_json(resp.result)!
	}
}

fn (mut app App) openai_resolved_plan_from_plugin_result_with_defaults(model string, body string, raw string, default_path string, default_output_protocol string) !OpenAIResolvedPlan {
	plan := openai_upstream_plan_from_plugin_json_with_defaults(raw, default_path, default_output_protocol)!
	backend_name := plan.backend.trim_space()
	if backend_name == '' {
		return openai_plan_error('openai_plugin_plan_missing_backend', 'plugin plan must include backend')
	}
	backend := app.openai_backends[backend_name] or {
		return openai_plan_error('openai_plugin_plan_unknown_backend', 'unknown backend ${backend_name}')
	}
	plan_method := openai_validate_plan_method(plan.method)!
	plan_path := openai_validate_plan_path(plan.path)!
	stream_mode := openai_validate_stream_mode(plan.stream_mode)!
	response_codec := openai_validate_response_codec(plan.response_codec, stream_mode)!
	output_protocol := openai_validate_output_protocol(plan.output_protocol, stream_mode)!
	mapper := openai_validate_mapper(plan.mapper)!
	plan_headers := openai_sanitize_plan_headers(plan.headers)
	plan_body := if plan.body.trim_space() != '' {
		plan.body
	} else {
		openai_replace_model_in_body(body, plan.upstream_model)
	}
	return OpenAIResolvedPlan{
		backend_name:    backend_name
		backend:         backend
		method:          plan_method
		path:            plan_path
		body:            plan_body
		model:           model
		stream_mode:     stream_mode
		response_codec:  response_codec
		output_protocol: output_protocol
		mapper:          mapper
		headers:         plan_headers
	}
}

fn (mut app App) openai_resolved_plan_from_plugin_result(model string, body string, raw string) !OpenAIResolvedPlan {
	return app.openai_resolved_plan_from_plugin_result_with_defaults(model, body, raw,
		'/chat/completions', 'openai.chat.completion')
}

fn (mut app App) openai_plugin_plan(model string, body string, method string, path string, req_id string, trace_id string) !OpenAIPluginPlanResult {
	resp := app.openai_call_plugin('chat.route', json.encode(OpenAIPluginChatPayload{
		method:     method.to_upper()
		path:       path
		model:      model
		stream:     openai_is_stream_request(body)
		body:       body
		base_path:  app.openai_base_path
		request_id: req_id
		trace_id:   trace_id
	}), req_id, trace_id, {
		'model': model
	})!
	if openai_plugin_not_handled(resp.result) {
		return OpenAIPluginPlanResult{}
	}
	return OpenAIPluginPlanResult{
		handled: true
		plan:    app.openai_resolved_plan_from_plugin_result(model, body, resp.result)!
	}
}

fn (mut app App) openai_plugin_responses_plan(model string, body string, method string, path string, req_id string, trace_id string) !OpenAIPluginPlanResult {
	resp := app.openai_call_plugin('responses.route', json.encode(OpenAIPluginResponsesPayload{
		method:     method.to_upper()
		path:       path
		model:      model
		stream:     openai_is_stream_request(body)
		body:       body
		base_path:  app.openai_base_path
		request_id: req_id
		trace_id:   trace_id
	}), req_id, trace_id, {
		'model': model
	})!
	if openai_plugin_not_handled(resp.result) {
		return OpenAIPluginPlanResult{}
	}
	return OpenAIPluginPlanResult{
		handled: true
		plan:    app.openai_resolved_plan_from_plugin_result_with_defaults(model, body,
			resp.result, '/responses', 'openai.response')!
	}
}

fn (mut app App) openai_plugin_fallback_plan(model string, body string, method string, path string, failed_plan OpenAIResolvedPlan, status_code int, error_code string, error_message string, req_id string, trace_id string) !OpenAIPluginPlanResult {
	if app.openai_plugin.trim_space() == '' {
		return OpenAIPluginPlanResult{}
	}
	resp := app.openai_call_plugin('chat.fallback', json.encode(OpenAIPluginFallbackPayload{
		method:         method.to_upper()
		path:           path
		model:          model
		stream:         openai_is_stream_request(body)
		body:           body
		base_path:      app.openai_base_path
		failed_backend: failed_plan.backend_name
		status_code:    status_code
		error_code:     error_code
		error_message:  error_message
		request_id:     req_id
		trace_id:       trace_id
	}), req_id, trace_id, {
		'model':          model
		'failed_backend': failed_plan.backend_name
	})!
	if openai_plugin_not_handled(resp.result) {
		return OpenAIPluginPlanResult{}
	}
	return OpenAIPluginPlanResult{
		handled: true
		plan:    app.openai_resolved_plan_from_plugin_result(model, body, resp.result)!
	}
}

fn (mut app App) openai_call_executor_op(plan OpenAIResolvedPlan, op string, method string, path string, req_id string, trace_id string) !PluginCallResponse {
	executor_name := plan.backend.executor.trim_space()
	if executor_name == '' {
		return error('openai_executor_missing_name:${plan.backend_name}')
	}
	return app.call_plugin(PluginCallRequest{
		plugin:     executor_name
		capability: 'openai'
		op:         op
		request_id: req_id
		trace_id:   trace_id
		payload:    json.encode(OpenAIExecutorPayload{
			method:          method.to_upper()
			path:            path
			model:           plan.model
			stream:          openai_is_stream_request(plan.body)
			body:            plan.body
			backend:         plan.backend_name
			request_id:      req_id
			trace_id:        trace_id
			response_codec:  plan.response_codec
			output_protocol: plan.output_protocol
		})
		metadata:   {
			'model':   plan.model
			'backend': plan.backend_name
		}
	})
}

fn (mut app App) openai_call_executor(plan OpenAIResolvedPlan, method string, path string, req_id string, trace_id string) !PluginCallResponse {
	return app.openai_call_executor_op(plan, 'chat.execute', method, path, req_id, trace_id)
}

fn (mut app App) openai_call_executor_stream_op(plan OpenAIResolvedPlan, op string, method string, path string, req_id string, trace_id string, on_frame PluginStreamFrameFn) !PluginStreamCallResponse {
	executor_name := plan.backend.executor.trim_space()
	if executor_name == '' {
		return error('openai_executor_missing_name:${plan.backend_name}')
	}
	return app.call_plugin_stream(PluginCallRequest{
		plugin:     executor_name
		capability: 'openai'
		op:         op
		request_id: req_id
		trace_id:   trace_id
		payload:    json.encode(OpenAIExecutorPayload{
			method:          method.to_upper()
			path:            path
			model:           plan.model
			stream:          openai_is_stream_request(plan.body)
			body:            plan.body
			backend:         plan.backend_name
			request_id:      req_id
			trace_id:        trace_id
			response_codec:  plan.response_codec
			output_protocol: plan.output_protocol
		})
		metadata:   {
			'model':   plan.model
			'backend': plan.backend_name
		}
	}, on_frame)
}

fn (mut app App) openai_call_executor_stream(plan OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, on_frame PluginStreamFrameFn) !PluginStreamCallResponse {
	return app.openai_call_executor_stream_op(plan, 'chat.execute', method, path, req_id,
		trace_id, on_frame)
}

fn (mut app App) openai_resolve_plan(model string, body string, method string, path string, req_id string, trace_id string) !OpenAIResolvedPlan {
	if app.openai_plugin.trim_space() != '' {
		result := app.openai_plugin_plan(model, body, method, path, req_id, trace_id)!
		if result.handled {
			return result.plan
		}
	}
	route := app.openai_resolve_route(model)!
	return openai_builtin_plan_from_route(route, body)
}

fn (mut app App) openai_resolve_responses_plan(model string, body string, method string, path string, req_id string, trace_id string) !OpenAIResolvedPlan {
	if app.openai_plugin.trim_space() != '' {
		result := app.openai_plugin_responses_plan(model, body, method, path, req_id,
			trace_id)!
		if result.handled {
			return result.plan
		}
	}
	route := app.openai_resolve_route(model)!
	return openai_builtin_plan_from_route_for_endpoint(route, body, '/responses', 'openai.response')
}

fn (mut app App) openai_resolve_responses_passthrough_plan(relative_target string, body string, method string) !OpenAIResolvedPlan {
	model := openai_request_model(body)
	if model.trim_space() != '' {
		route := app.openai_resolve_route(model)!
		return openai_builtin_plan_from_route_for_endpoint_method(route, body, relative_target,
			'openai.response', method)
	}
	backend_name := app.openai_default_backend.trim_space()
	if backend_name == '' {
		return error('openai_responses_passthrough_missing_default_backend')
	}
	backend := app.openai_backends[backend_name] or {
		return error('unknown backend ${backend_name}')
	}
	return OpenAIResolvedPlan{
		backend_name:    backend_name
		backend:         backend
		method:          method.to_upper()
		path:            relative_target
		body:            body
		model:           model
		stream_mode:     'passthrough'
		response_codec:  'sse'
		output_protocol: 'openai.response'
		mapper:          'builtin'
		headers:         map[string]string{}
	}
}

fn openai_error(mut app App, mut ctx Context, status int, path string, method string, req_id string, trace_id string, start_ms i64, code string, message string) veb.Result {
	return openai_error_typed(mut app, mut ctx, status, path, method, req_id, trace_id,
		start_ms, code, message, 'invalid_request_error')
}

fn openai_error_typed(mut app App, mut ctx Context, status int, path string, method string, req_id string, trace_id string, start_ms i64, code string, message string, typ string) veb.Result {
	body := openai_error_body_json(code, message, typ)
	ctx.res.set_status(http.status_from_int(status))
	ctx.set_content_type('application/json; charset=utf-8')
	ctx.set_custom_header('x-request-id', req_id) or {}
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        normalize_path(path)
		'status':      '${status}'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'provider':    'openai'
	})
	return ctx.text(body)
}

fn openai_error_body_json(code string, message string, typ string) string {
	return json.encode(OpenAIErrorResponse{
		error: OpenAIErrorBody{
			message: message
			typ:     typ
			code:    code
		}
	})
}

fn openai_upstream_error_from_body(body string, fallback_code string, fallback_message string) (string, string, string) {
	parsed := json2.decode[json2.Any](body) or {
		trimmed := body.trim_space()
		return fallback_code, if trimmed == '' {
			fallback_message
		} else {
			trimmed
		}, 'server_error'
	}
	root := parsed.as_map()
	if error_any := root['error'] {
		error_obj := error_any.as_map()
		message := (error_obj['message'] or { json2.Any(fallback_message) }).str()
		code := (error_obj['code'] or { json2.Any(fallback_code) }).str()
		typ := (error_obj['type'] or { json2.Any('server_error') }).str()
		return if code == '' { fallback_code } else { code }, if message == '' {
			fallback_message
		} else {
			message
		}, if typ == '' {
			'server_error'
		} else {
			typ
		}
	}
	message := (root['message'] or { json2.Any(fallback_message) }).str()
	code := (root['code'] or { json2.Any(fallback_code) }).str()
	typ := (root['type'] or { json2.Any('server_error') }).str()
	return if code == '' { fallback_code } else { code }, if message == '' {
		fallback_message
	} else {
		message
	}, if typ == '' {
		'server_error'
	} else {
		typ
	}
}

fn openai_write_error_response_conn(mut conn net.TcpConn, status int, headers map[string]string, code string, message string, typ string) {
	write_http_stream_headers_conn(mut conn, status, 'application/json; charset=utf-8',
		headers, false) or {}
	conn.write_string(openai_error_body_json(code, message, typ)) or {}
}

fn openai_write_sse_error(mut conn net.TcpConn, code string, message string, typ string) {
	write_chunk(mut conn, 'data: ${openai_error_body_json(code, message, typ)}\n\n') or {}
	write_chunk(mut conn, 'data: [DONE]\n\n') or {}
}

fn openai_finish_passthrough_stream(mut state OpenAIStreamProxyState) ! {
	if state.headers_written && !state.final_written {
		write_final_chunk(mut state.conn)!
		state.final_written = true
	}
}

fn openai_finish_mapped_stream(mut state OpenAIMappedStreamProxyState) ! {
	if state.headers_written && !state.final_written {
		write_final_chunk(mut state.conn)!
		state.final_written = true
	}
}

fn openai_passthrough_chunk_has_done(mut state OpenAIStreamProxyState, decoded string) bool {
	if decoded == '' {
		return false
	}
	combined := state.done_probe + decoded
	if combined.contains('data: [DONE]') {
		state.done = true
		return true
	}
	state.done_probe = if combined.len > 64 { combined[combined.len - 64..] } else { combined }
	return false
}

fn openai_build_upstream_url(base_url string, relative string) string {
	mut base := base_url.trim_space()
	for base.ends_with('/') {
		base = base[..base.len - 1]
	}
	return '${base}${relative}'
}

fn openai_backend_auth_key(backend OpenAIBackendConfig) string {
	if backend.api_key.trim_space() != '' {
		return backend.api_key.trim_space()
	}
	if backend.api_key_env.trim_space() != '' {
		return os.getenv(backend.api_key_env.trim_space())
	}
	return ''
}

fn openai_http_method(raw string, fallback string) http.Method {
	return match raw.trim_space().to_upper() {
		'GET' {
			.get
		}
		'PUT' {
			.put
		}
		'PATCH' {
			.patch
		}
		'DELETE' {
			.delete
		}
		'HEAD' {
			.head
		}
		else {
			match fallback.trim_space().to_upper() {
				'HEAD' { .head }
				else { .post }
			}
		}
	}
}

fn openai_build_headers(mut ctx Context, backend OpenAIBackendConfig, req_id string, stream bool, extra map[string]string) http.Header {
	mut header := http.new_header()
	content_type := ctx.req.header.get(.content_type) or { 'application/json' }
	accept := if stream { 'text/event-stream' } else { ctx.req.header.get(.accept) or {
			'application/json'} }
	header.add(.content_type, content_type)
	header.add(.accept, accept)
	header.add_custom('x-request-id', req_id) or {}
	api_key := openai_backend_auth_key(backend)
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

fn ensure_openai_stream_headers_written(mut state OpenAIStreamProxyState) ! {
	if state.headers_written {
		return
	}
	mut headers := state.response_headers.clone()
	headers['x-accel-buffering'] = 'no'
	write_http_stream_headers_conn_with_close(mut state.conn, state.status_code, state.content_type,
		headers, true, false)!
	state.headers_written = true
}

fn openai_progress_body_cb(request &http.Request, chunk []u8, _body_read_so_far u64, _body_expected_size u64, status_code int) ! {
	mut state := &OpenAIStreamProxyState(unsafe { nil })
	pstate := unsafe { &voidptr(&state) }
	unsafe {
		*pstate = request.user_ptr
	}
	if status_code > 0 {
		state.status_code = status_code
	}
	decoded := openai_decode_progress_chunk(mut state.chunk_decoder, chunk)
	if state.status_code >= 400 {
		if decoded.len > 0 {
			state.error_body += decoded
		}
		return
	}
	ensure_openai_stream_headers_written(mut state)!
	if state.method.to_upper() != 'HEAD' && decoded.len > 0 {
		write_chunk(mut state.conn, decoded)!
	}
	if openai_passthrough_chunk_has_done(mut state, decoded) {
		openai_finish_passthrough_stream(mut state)!
		return error(openai_stream_done_fetch_error)
	}
}

fn ensure_openai_mapped_stream_headers_written(mut state OpenAIMappedStreamProxyState) ! {
	if state.headers_written {
		return
	}
	mut headers := state.response_headers.clone()
	headers['x-accel-buffering'] = 'no'
	write_http_stream_headers_conn_with_close(mut state.conn, state.status_code, 'text/event-stream',
		headers, true, false)!
	state.headers_written = true
}

fn openai_extract_mapped_row(line string) OpenAIFrameMapping {
	parsed := json2.decode[json2.Any](line) or { return OpenAIFrameMapping{} }
	root := parsed.as_map()
	done := (root['done'] or { json2.Any(false) }).bool()
	mut tool_calls := []json2.Any{}
	usage := openai_usage_from_map(root)
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

fn openai_int_field(obj map[string]json2.Any, key string) int {
	value := obj[key] or { return 0 }
	return value.int()
}

fn openai_usage_from_map(root map[string]json2.Any) map[string]int {
	if usage_any := root['usage'] {
		usage := usage_any.as_map()
		prompt := openai_int_field(usage, 'prompt_tokens')
		completion := openai_int_field(usage, 'completion_tokens')
		total_raw := openai_int_field(usage, 'total_tokens')
		total := if total_raw > 0 { total_raw } else { prompt + completion }
		if prompt > 0 || completion > 0 || total > 0 {
			return {
				'prompt_tokens':     prompt
				'completion_tokens': completion
				'total_tokens':      total
			}
		}
	}
	prompt := openai_int_field(root, 'prompt_tokens') + openai_int_field(root, 'prompt_eval_count')
	completion := openai_int_field(root, 'completion_tokens') + openai_int_field(root, 'eval_count')
	total_raw := openai_int_field(root, 'total_tokens')
	total := if total_raw > 0 { total_raw } else { prompt + completion }
	if prompt > 0 || completion > 0 || total > 0 {
		return {
			'prompt_tokens':     prompt
			'completion_tokens': completion
			'total_tokens':      total
		}
	}
	return map[string]int{}
}

fn openai_merge_usage(mut acc map[string]int, usage map[string]int) {
	for key, value in usage {
		if value > 0 {
			acc[key] = value
		}
	}
}

fn openai_stream_chunk_json(state OpenAIMappedStreamProxyState, mapping OpenAIFrameMapping) string {
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

fn openai_usage_json_obj(usage map[string]int) map[string]json2.Any {
	return {
		'prompt_tokens':     json2.Any(usage['prompt_tokens'])
		'completion_tokens': json2.Any(usage['completion_tokens'])
		'total_tokens':      json2.Any(usage['total_tokens'])
	}
}

fn openai_stream_usage_chunk_json(state OpenAIMappedStreamProxyState) string {
	mut root := map[string]json2.Any{}
	root['id'] = json2.Any('chatcmpl-${state.request_id}')
	root['object'] = json2.Any('chat.completion.chunk')
	root['created'] = json2.Any(state.created)
	root['model'] = json2.Any(state.model)
	root['choices'] = json2.Any([]json2.Any{})
	root['usage'] = json2.Any(openai_usage_json_obj(state.usage))
	return json2.Any(root).json_str()
}

fn openai_write_stream_usage_chunk(mut state OpenAIMappedStreamProxyState) ! {
	if state.usage.len == 0 {
		return
	}
	ensure_openai_mapped_stream_headers_written(mut state)!
	write_chunk(mut state.conn, 'data: ${openai_stream_usage_chunk_json(state)}\n\n')!
}

fn openai_tool_call_index(call map[string]json2.Any, fallback int) int {
	index_any := call['index'] or { return fallback }
	return index_any.int()
}

fn openai_merge_tool_call(existing map[string]json2.Any, incoming map[string]json2.Any) map[string]json2.Any {
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

fn openai_merge_tool_calls(mut acc []json2.Any, calls []json2.Any) {
	for call_any in calls {
		call := call_any.as_map()
		index := openai_tool_call_index(call, acc.len)
		mut found := -1
		for i, existing_any in acc {
			existing := existing_any.as_map()
			if openai_tool_call_index(existing, i) == index {
				found = i
				break
			}
		}
		if found < 0 {
			acc << json2.Any(call)
			continue
		}
		acc[found] = json2.Any(openai_merge_tool_call(acc[found].as_map(), call))
	}
}

fn openai_plugin_map_frame_result(raw string) OpenAIFrameMapping {
	if openai_plugin_not_handled(raw) {
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
	usage := openai_usage_from_map(root)
	done := (root['done'] or { json2.Any(false) }).bool()
	return OpenAIFrameMapping{
		content:       content
		tool_calls:    tool_calls
		usage:         usage
		done:          done
		handled:       true
		finish_reason: openai_json_string_field(root, 'finish_reason', if tool_calls.len > 0 {
			'tool_calls'
		} else {
			''
		})
	}
}

fn (mut app App) openai_plugin_map_frame(plan OpenAIResolvedPlan, frame string, req_id string, trace_id string) !OpenAIFrameMapping {
	resp := app.openai_call_plugin('chat.map_frame', json.encode(OpenAIPluginMapFramePayload{
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
	return openai_plugin_map_frame_result(resp.result)
}

fn openai_map_line_with_plugin(mut state OpenAIMappedStreamProxyState, line string) OpenAIFrameMapping {
	mut app := unsafe { &App(state.app) }
	return app.openai_plugin_map_frame(OpenAIResolvedPlan{
		model:           state.model
		response_codec:  state.response_codec
		output_protocol: state.output_protocol
	}, line, state.request_id, state.trace_id) or {
		return OpenAIFrameMapping{
			done:    true
			handled: true
			error:   err.msg()
		}
	}
}

fn openai_write_mapped_stream_line(mut state OpenAIMappedStreamProxyState, line string) ! {
	trimmed := line.trim_space()
	if trimmed == '' {
		return
	}
	mapping := if state.mapper == 'plugin' {
		plugin_mapping := openai_map_line_with_plugin(mut state, trimmed)
		if plugin_mapping.error != '' {
			state.mapper_error = plugin_mapping.error
		}
		if plugin_mapping.handled {
			plugin_mapping
		} else {
			openai_extract_mapped_row(trimmed)
		}
	} else {
		openai_extract_mapped_row(trimmed)
	}
	if mapping.error != '' {
		state.mapper_error = mapping.error
		ensure_openai_mapped_stream_headers_written(mut state)!
		openai_write_sse_error(mut state.conn, 'mapper_error', mapping.error, 'server_error')
		state.done = true
		openai_finish_mapped_stream(mut state)!
		return
	}
	if mapping.content != '' || mapping.tool_calls.len > 0 {
		ensure_openai_mapped_stream_headers_written(mut state)!
		write_chunk(mut state.conn, 'data: ${openai_stream_chunk_json(state, mapping)}\n\n')!
	}
	openai_merge_usage(mut state.usage, mapping.usage)
	if mapping.done && !state.done {
		ensure_openai_mapped_stream_headers_written(mut state)!
		openai_write_stream_usage_chunk(mut state)!
		write_chunk(mut state.conn, 'data: [DONE]\n\n')!
		state.done = true
		openai_finish_mapped_stream(mut state)!
	}
}

fn openai_mapped_progress_body_cb(request &http.Request, chunk []u8, _body_read_so_far u64, _body_expected_size u64, status_code int) ! {
	mut state := &OpenAIMappedStreamProxyState(unsafe { nil })
	pstate := unsafe { &voidptr(&state) }
	unsafe {
		*pstate = request.user_ptr
	}
	if status_code > 0 {
		state.status_code = status_code
	}
	decoded := openai_decode_progress_chunk(mut state.chunk_decoder, chunk)
	if state.status_code >= 400 {
		if decoded.len > 0 {
			state.error_body += decoded
		}
		return
	}
	if state.method.to_upper() == 'HEAD' || decoded.len == 0 {
		return
	}
	state.line_buffer += decoded
	for state.line_buffer.contains('\n') {
		line := state.line_buffer.all_before('\n')
		state.line_buffer = state.line_buffer.all_after('\n')
		openai_write_mapped_stream_line(mut state, line)!
	}
	if state.done {
		return error(openai_stream_done_fetch_error)
	}
}

fn openai_reset_mapped_stream_state_for_plan(mut state OpenAIMappedStreamProxyState, plan OpenAIResolvedPlan) {
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

fn openai_fetch_mapped_stream(mut ctx Context, mut state OpenAIMappedStreamProxyState, plan OpenAIResolvedPlan, method string, req_id string) string {
	_ := http.fetch(
		url:                openai_build_upstream_url(plan.backend.base_url, plan.path)
		method:             openai_http_method(plan.method, method)
		header:             openai_build_headers(mut ctx, plan.backend, req_id, true,
			plan.headers)
		data:               plan.body
		on_progress_body:   openai_mapped_progress_body_cb
		user_ptr:           state
		stop_copying_limit: 65536
	) or {
		if err.msg() == openai_stream_done_fetch_error {
			return ''
		}
		return err.msg()
	}
	return ''
}

fn openai_proxy_mapped_stream(mut app App, mut ctx Context, plan OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if plan.response_codec != 'ndjson' || plan.output_protocol != 'openai.chat.completion' {
		return openai_error(mut app, mut ctx, 502, path, method, req_id, trace_id, start_ms,
			'openai_plugin_plan_unsupported_mapper', 'unsupported mapper ${plan.response_codec} -> ${plan.output_protocol}')
	}
	if plan.backend.kind.trim_space() !in ['', 'openai_http', 'http'] {
		return openai_error(mut app, mut ctx, 502, path, method, req_id, trace_id, start_ms,
			'unsupported_backend', 'unsupported OpenAI backend kind ${plan.backend.kind}')
	}
	if plan.backend.base_url.trim_space() == '' {
		return openai_error(mut app, mut ctx, 502, path, method, req_id, trace_id, start_ms,
			'missing_backend_base_url', 'OpenAI backend ${plan.backend_name} has no base_url')
	}
	ctx.takeover_conn_reusable()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut client_conn := ctx.conn
	mut headers := map[string]string{}
	headers['x-request-id'] = req_id
	headers['x-vhttpd-trace-id'] = trace_id
	headers['x-vhttpd-openai-backend'] = plan.backend_name
	mut state := &OpenAIMappedStreamProxyState{
		app:              unsafe { &app }
		conn:             client_conn
		method:           method
		status_code:      200
		response_headers: headers
		model:            plan.model
		request_id:       req_id
		trace_id:         trace_id
		mapper:           plan.mapper
		response_codec:   plan.response_codec
		output_protocol:  plan.output_protocol
		created:          int(time.now().unix())
	}
	mut fetch_err_msg := openai_fetch_mapped_stream(mut ctx, mut state, plan, method,
		req_id)
	if fetch_err_msg != '' && !state.headers_written {
		fallback := app.openai_plugin_fallback_plan(plan.model, plan.body, method, path,
			plan, 502, 'upstream_fetch_failed', fetch_err_msg, req_id, trace_id) or {
			OpenAIPluginPlanResult{}
		}
		if fallback.handled && fallback.plan.stream_mode == 'mapped' {
			openai_reset_mapped_stream_state_for_plan(mut state, fallback.plan)
			fallback_err_msg := openai_fetch_mapped_stream(mut ctx, mut state, fallback.plan,
				method, req_id)
			if fallback_err_msg == '' {
				fetch_err_msg = ''
			} else {
				fetch_err_msg = fallback_err_msg
			}
		}
	}
	if fetch_err_msg != '' && !state.headers_written {
		err_headers := {
			'x-request-id':         req_id
			'x-vhttpd-trace-id':    trace_id
			'x-vhttpd-error-class': 'openai_upstream_fetch_failed'
		}
		openai_write_error_response_conn(mut client_conn, 502, err_headers, 'upstream_fetch_failed',
			fetch_err_msg, 'server_error')
		client_conn.close() or {}
		return veb.no_result()
	}
	if state.status_code >= 400 && !state.headers_written {
		code, message, _ := openai_upstream_error_from_body(state.error_body, 'upstream_error',
			'upstream returned HTTP ${state.status_code}')
		fallback := app.openai_plugin_fallback_plan(plan.model, plan.body, method, path,
			plan, state.status_code, code, message, req_id, trace_id) or {
			OpenAIPluginPlanResult{}
		}
		if fallback.handled && fallback.plan.stream_mode == 'mapped' {
			openai_reset_mapped_stream_state_for_plan(mut state, fallback.plan)
			fallback_err_msg := openai_fetch_mapped_stream(mut ctx, mut state, fallback.plan,
				method, req_id)
			if fallback_err_msg != '' && !state.headers_written {
				err_headers := {
					'x-request-id':         req_id
					'x-vhttpd-trace-id':    trace_id
					'x-vhttpd-error-class': 'openai_upstream_fetch_failed'
				}
				openai_write_error_response_conn(mut client_conn, 502, err_headers, 'upstream_fetch_failed',
					fallback_err_msg, 'server_error')
				client_conn.close() or {}
				return veb.no_result()
			}
		}
	}
	if state.status_code >= 400 && !state.headers_written {
		code, message, typ := openai_upstream_error_from_body(state.error_body, 'upstream_error',
			'upstream returned HTTP ${state.status_code}')
		err_headers := {
			'x-request-id':         req_id
			'x-vhttpd-trace-id':    trace_id
			'x-vhttpd-error-class': 'openai_upstream_error'
		}
		openai_write_error_response_conn(mut client_conn, state.status_code, err_headers,
			code, message, typ)
		client_conn.close() or {}
		return veb.no_result()
	}
	if state.line_buffer.trim_space() != '' {
		openai_write_mapped_stream_line(mut state, state.line_buffer) or {}
		state.line_buffer = ''
	}
	if state.mapper_error != '' && !state.final_written {
		ensure_openai_mapped_stream_headers_written(mut state) or {}
		openai_write_sse_error(mut client_conn, 'mapper_error', state.mapper_error, 'server_error')
		state.done = true
		openai_finish_mapped_stream(mut state) or {}
	}
	if !state.done {
		ensure_openai_mapped_stream_headers_written(mut state) or {}
		openai_write_stream_usage_chunk(mut state) or {}
		write_chunk(mut client_conn, 'data: [DONE]\n\n') or {}
		state.done = true
	}
	if state.headers_written {
		openai_finish_mapped_stream(mut state) or {}
	}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        normalize_path(path)
		'status':      '${state.status_code}'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'provider':    'openai'
		'backend':     plan.backend_name
		'mapper':      '${plan.response_codec}->${plan.output_protocol}'
	})
	return veb.no_result()
}

fn openai_fetch_passthrough_stream(mut ctx Context, mut state OpenAIStreamProxyState, plan OpenAIResolvedPlan, method string, req_id string) string {
	_ := http.fetch(
		url:                openai_build_upstream_url(plan.backend.base_url, plan.path)
		method:             openai_http_method(plan.method, method)
		header:             openai_build_headers(mut ctx, plan.backend, req_id, true,
			plan.headers)
		data:               plan.body
		on_progress_body:   openai_progress_body_cb
		user_ptr:           state
		stop_copying_limit: 65536
	) or { return err.msg() }
	return ''
}

fn openai_proxy_stream(mut app App, mut ctx Context, plan OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if plan.backend.kind.trim_space() !in ['', 'openai_http'] {
		return openai_error(mut app, mut ctx, 502, path, method, req_id, trace_id, start_ms,
			'unsupported_backend', 'unsupported OpenAI backend kind ${plan.backend.kind}')
	}
	if plan.backend.base_url.trim_space() == '' {
		return openai_error(mut app, mut ctx, 502, path, method, req_id, trace_id, start_ms,
			'missing_backend_base_url', 'OpenAI backend ${plan.backend_name} has no base_url')
	}
	ctx.takeover_conn_reusable()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut client_conn := ctx.conn
	mut headers := map[string]string{}
	headers['x-request-id'] = req_id
	headers['x-vhttpd-trace-id'] = trace_id
	headers['x-vhttpd-openai-backend'] = plan.backend_name
	mut state := &OpenAIStreamProxyState{
		conn:             client_conn
		method:           method
		status_code:      200
		content_type:     'text/event-stream'
		response_headers: headers
	}
	fetch_method := openai_http_method(plan.method, method)
	mut fetch_err_msg := ''
	_ := http.fetch(
		url:                openai_build_upstream_url(plan.backend.base_url, plan.path)
		method:             fetch_method
		header:             openai_build_headers(mut ctx, plan.backend, req_id, true,
			plan.headers)
		data:               plan.body
		on_progress_body:   openai_progress_body_cb
		user_ptr:           state
		stop_copying_limit: 65536
	) or {
		if err.msg() == openai_stream_done_fetch_error {
			fetch_err_msg = ''
		} else {
			fetch_err_msg = err.msg()
		}
		http.Response{}
	}
	if fetch_err_msg != '' && !state.headers_written {
		fallback := app.openai_plugin_fallback_plan(plan.model, plan.body, method, path,
			plan, 502, 'upstream_fetch_failed', fetch_err_msg, req_id, trace_id) or {
			OpenAIPluginPlanResult{}
		}
		if fallback.handled && fallback.plan.stream_mode == 'passthrough' {
			state.status_code = 200
			state.error_body = ''
			state.chunk_decoder = OpenAIChunkDecodeState{}
			state.done = false
			state.done_probe = ''
			state.final_written = false
			state.response_headers['x-vhttpd-openai-backend'] = fallback.plan.backend_name
			fallback_err_msg := openai_fetch_passthrough_stream(mut ctx, mut state, fallback.plan,
				method, req_id)
			if fallback_err_msg == '' {
				fetch_err_msg = ''
			} else {
				fetch_err_msg = fallback_err_msg
			}
		}
	}
	if fetch_err_msg != '' && !state.headers_written {
		err_headers := {
			'x-request-id':         req_id
			'x-vhttpd-trace-id':    trace_id
			'x-vhttpd-error-class': 'openai_upstream_fetch_failed'
		}
		openai_write_error_response_conn(mut client_conn, 502, err_headers, 'upstream_fetch_failed',
			fetch_err_msg, 'server_error')
		client_conn.close() or {}
		return veb.no_result()
	}
	if state.status_code >= 400 && !state.headers_written {
		code, message, typ := openai_upstream_error_from_body(state.error_body, 'upstream_error',
			'upstream returned HTTP ${state.status_code}')
		fallback := app.openai_plugin_fallback_plan(plan.model, plan.body, method, path,
			plan, state.status_code, code, message, req_id, trace_id) or {
			OpenAIPluginPlanResult{}
		}
		if fallback.handled && fallback.plan.stream_mode == 'passthrough' {
			state.status_code = 200
			state.error_body = ''
			state.chunk_decoder = OpenAIChunkDecodeState{}
			state.done = false
			state.done_probe = ''
			state.final_written = false
			state.response_headers['x-vhttpd-openai-backend'] = fallback.plan.backend_name
			fallback_err_msg := openai_fetch_passthrough_stream(mut ctx, mut state, fallback.plan,
				method, req_id)
			if fallback_err_msg == '' && state.status_code < 400 {
				if !state.headers_written {
					ensure_openai_stream_headers_written(mut state) or {}
				}
				if state.headers_written {
					openai_finish_passthrough_stream(mut state) or {}
				}
				return veb.no_result()
			}
		}
		if state.status_code >= 400 {
			code2, message2, typ2 := openai_upstream_error_from_body(state.error_body,
				'upstream_error', 'upstream returned HTTP ${state.status_code}')
			err_headers := {
				'x-request-id':         req_id
				'x-vhttpd-trace-id':    trace_id
				'x-vhttpd-error-class': 'openai_upstream_error'
			}
			openai_write_error_response_conn(mut client_conn, state.status_code, err_headers,
				code2, message2, typ2)
			client_conn.close() or {}
			return veb.no_result()
		}
		err_headers := {
			'x-request-id':         req_id
			'x-vhttpd-trace-id':    trace_id
			'x-vhttpd-error-class': 'openai_upstream_error'
		}
		openai_write_error_response_conn(mut client_conn, state.status_code, err_headers,
			code, message, typ)
		client_conn.close() or {}
		return veb.no_result()
	}
	if !state.headers_written {
		ensure_openai_stream_headers_written(mut state) or {}
	}
	if state.headers_written {
		openai_finish_passthrough_stream(mut state) or {}
	}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        normalize_path(path)
		'status':      '${state.status_code}'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'provider':    'openai'
		'backend':     plan.backend_name
	})
	return veb.no_result()
}

fn openai_proxy_once(mut app App, mut ctx Context, plan OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	return openai_proxy_once_attempt(mut app, mut ctx, plan, method, path, req_id, trace_id,
		start_ms, true)
}

fn openai_proxy_once_attempt(mut app App, mut ctx Context, plan OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64, allow_fallback bool) veb.Result {
	if plan.backend.kind.trim_space() == 'executor' {
		return openai_proxy_executor_once(mut app, mut ctx, plan, method, path, req_id,
			trace_id, start_ms)
	}
	if plan.backend.kind.trim_space() !in ['', 'openai_http', 'http'] {
		return openai_error(mut app, mut ctx, 502, path, method, req_id, trace_id, start_ms,
			'unsupported_backend', 'unsupported OpenAI backend kind ${plan.backend.kind}')
	}
	if plan.backend.base_url.trim_space() == '' {
		return openai_error(mut app, mut ctx, 502, path, method, req_id, trace_id, start_ms,
			'missing_backend_base_url', 'OpenAI backend ${plan.backend_name} has no base_url')
	}
	resp := http.fetch(
		url:    openai_build_upstream_url(plan.backend.base_url, plan.path)
		method: openai_http_method(plan.method, method)
		header: openai_build_headers(mut ctx, plan.backend, req_id, false, plan.headers)
		data:   plan.body
	) or {
		if allow_fallback {
			fallback := app.openai_plugin_fallback_plan(plan.model, plan.body, method,
				path, plan, 502, 'upstream_fetch_failed', err.msg(), req_id, trace_id) or {
				OpenAIPluginPlanResult{}
			}
			if fallback.handled {
				return openai_proxy_once_attempt(mut app, mut ctx, fallback.plan, method,
					path, req_id, trace_id, start_ms, false)
			}
		}
		return openai_error(mut app, mut ctx, 502, path, method, req_id, trace_id, start_ms,
			'upstream_fetch_failed', err.msg())
	}
	if resp.status_code >= 400 {
		code, message, typ := openai_upstream_error_from_body(resp.body, 'upstream_error',
			'upstream returned HTTP ${resp.status_code}')
		if allow_fallback {
			fallback := app.openai_plugin_fallback_plan(plan.model, plan.body, method,
				path, plan, resp.status_code, code, message, req_id, trace_id) or {
				OpenAIPluginPlanResult{}
			}
			if fallback.handled {
				return openai_proxy_once_attempt(mut app, mut ctx, fallback.plan, method,
					path, req_id, trace_id, start_ms, false)
			}
		}
		return openai_error_typed(mut app, mut ctx, resp.status_code, path, method, req_id,
			trace_id, start_ms, code, message, typ)
	}
	ctx.res.set_status(http.status_from_int(resp.status_code))
	ctx.set_content_type(if plan.stream_mode == 'mapped' {
		'application/json; charset=utf-8'
	} else {
		openai_response_content_type(resp.header, 'application/json; charset=utf-8')
	})
	ctx.set_custom_header('x-request-id', req_id) or {}
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_custom_header('x-vhttpd-openai-backend', plan.backend_name) or {}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        normalize_path(path)
		'status':      '${resp.status_code}'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'provider':    'openai'
		'backend':     plan.backend_name
	})
	if plan.stream_mode == 'mapped' {
		mapped_body := openai_map_once_response(plan, resp.body, req_id, int(time.now().unix())) or {
			return openai_error(mut app, mut ctx, 502, path, method, req_id, trace_id,
				start_ms, openai_plan_error_code(err.msg()), openai_plan_error_message(err.msg()))
		}
		return ctx.text(if method.to_upper() == 'HEAD' { '' } else { mapped_body })
	}
	return ctx.text(if method.to_upper() == 'HEAD' { '' } else { resp.body })
}

fn openai_map_once_response(plan OpenAIResolvedPlan, body string, req_id string, created int) !string {
	if plan.response_codec !in ['ndjson', 'json']
		|| plan.output_protocol != 'openai.chat.completion' {
		return openai_plan_error('openai_plugin_plan_unsupported_mapper', 'unsupported mapper ${plan.response_codec} -> ${plan.output_protocol}')
	}
	mut content := ''
	mut tool_calls := []json2.Any{}
	mut usage := map[string]int{}
	if plan.response_codec == 'ndjson' {
		for line in body.split_into_lines() {
			mapping := openai_extract_mapped_row(line)
			content += mapping.content
			openai_merge_tool_calls(mut tool_calls, mapping.tool_calls)
			openai_merge_usage(mut usage, mapping.usage)
		}
	} else {
		mapping := openai_extract_mapped_row(body)
		content = mapping.content
		openai_merge_tool_calls(mut tool_calls, mapping.tool_calls)
		openai_merge_usage(mut usage, mapping.usage)
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
		root['usage'] = json2.Any(openai_usage_json_obj(usage))
	}
	return json2.Any(root).json_str()
}

fn openai_executor_mapping_from_result(raw string) OpenAIFrameMapping {
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
	return openai_plugin_map_frame_result(raw)
}

fn openai_completion_json_from_mapping(plan OpenAIResolvedPlan, mapping OpenAIFrameMapping, req_id string, created int) string {
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
		root['usage'] = json2.Any(openai_usage_json_obj(mapping.usage))
	}
	return json2.Any(root).json_str()
}

fn openai_executor_once_body(plan OpenAIResolvedPlan, raw string, req_id string, created int) string {
	parsed := json2.decode[json2.Any](raw) or {
		return openai_completion_json_from_mapping(plan, OpenAIFrameMapping{
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
	return openai_completion_json_from_mapping(plan, openai_executor_mapping_from_result(raw),
		req_id, created)
}

fn openai_responses_executor_once_body(plan OpenAIResolvedPlan, raw string, req_id string, created int) string {
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

fn openai_proxy_executor_once(mut app App, mut ctx Context, plan OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	resp := app.openai_call_executor(plan, method, path, req_id, trace_id) or {
		return openai_error(mut app, mut ctx, 502, path, method, req_id, trace_id, start_ms,
			'openai_executor_failed', err.msg())
	}
	body := openai_executor_once_body(plan, resp.result, req_id, int(time.now().unix()))
	ctx.res.set_status(.ok)
	ctx.set_content_type('application/json; charset=utf-8')
	ctx.set_custom_header('x-request-id', req_id) or {}
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_custom_header('x-vhttpd-openai-backend', plan.backend_name) or {}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        normalize_path(path)
		'status':      '200'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'provider':    'openai'
		'backend':     plan.backend_name
		'executor':    plan.backend.executor
	})
	return ctx.text(if method.to_upper() == 'HEAD' { '' } else { body })
}

fn openai_proxy_responses_executor_once(mut app App, mut ctx Context, plan OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	resp := app.openai_call_executor_op(plan, 'responses.execute', method, path, req_id,
		trace_id) or {
		return openai_error(mut app, mut ctx, 502, path, method, req_id, trace_id, start_ms,
			'openai_executor_failed', err.msg())
	}
	body := openai_responses_executor_once_body(plan, resp.result, req_id, int(time.now().unix()))
	app.openai_store_response_record(plan, body, req_id, trace_id)
	ctx.res.set_status(.ok)
	ctx.set_content_type('application/json; charset=utf-8')
	ctx.set_custom_header('x-request-id', req_id) or {}
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_custom_header('x-vhttpd-openai-backend', plan.backend_name) or {}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        normalize_path(path)
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

fn openai_executor_stream_mappings(raw string) []OpenAIFrameMapping {
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
			mappings << openai_plugin_map_frame_result(frame.json_str())
		}
		return mappings
	}
	return [openai_executor_mapping_from_result(raw)]
}

fn openai_response_stream_event_from_raw(raw string) string {
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

fn openai_response_body_from_completed_event(raw string) string {
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

fn openai_proxy_responses_executor_stream(mut app App, mut ctx Context, plan OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
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
	write_http_stream_headers_conn(mut client_conn, 200, 'text/event-stream', headers,
		true) or {}
	mut registry_state := &OpenAIResponsesStreamRegistryState{}
	stream_resp := app.openai_call_executor_stream_op(plan, 'responses.execute', method,
		path, req_id, trace_id, fn [mut client_conn, mut registry_state] (raw string) !bool {
		if registry_state.completed_body == '' {
			registry_state.completed_body = openai_response_body_from_completed_event(raw)
		}
		write_chunk(mut client_conn, openai_response_stream_event_from_raw(raw))!
		return true
	}) or {
		openai_write_sse_error(mut client_conn, 'openai_executor_failed', err.msg(), 'server_error')
		write_final_chunk(mut client_conn) or {}
		client_conn.close() or {}
		app.emit('http.request', {
			'method':      method.to_upper()
			'path':        normalize_path(path)
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
		for mapping in openai_executor_stream_mappings(stream_resp.response.result) {
			if mapping.error != '' {
				openai_write_sse_error(mut client_conn, 'openai_executor_error', mapping.error,
					'server_error')
				wrote_frame = true
				break
			}
			event := {
				'type':            json2.Any('response.output_text.delta')
				'delta':           json2.Any(mapping.content)
				'sequence_number': json2.Any(1)
			}
			if mapping.content != '' {
				write_chunk(mut client_conn, openai_response_stream_event_from_raw(json2.Any(event).json_str())) or {}
				wrote_frame = true
			}
			if mapping.done {
				registry_state.completed_body = '{"id":"resp_${req_id}","object":"response","status":"completed","model":"${plan.model}"}'
				write_chunk(mut client_conn, openai_response_stream_event_from_raw('{"type":"response.completed","sequence_number":2,"response":${registry_state.completed_body}}')) or {}
				wrote_frame = true
			}
		}
		if !wrote_frame {
			registry_state.completed_body = '{"id":"resp_${req_id}","object":"response","status":"completed","model":"${plan.model}"}'
			write_chunk(mut client_conn, openai_response_stream_event_from_raw('{"type":"response.completed","sequence_number":1,"response":${registry_state.completed_body}}')) or {}
		}
	}
	if registry_state.completed_body != '' {
		app.openai_store_response_record(plan, registry_state.completed_body, req_id,
			trace_id)
	}
	write_final_chunk(mut client_conn) or {}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        normalize_path(path)
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

fn openai_proxy_executor_stream(mut app App, mut ctx Context, plan OpenAIResolvedPlan, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
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
	stream_resp := app.openai_call_executor_stream(plan, method, path, req_id, trace_id,
		fn [mut state, mut client_conn] (raw string) !bool {
		mapping := openai_plugin_map_frame_result(raw)
		if mapping.error != '' {
			ensure_openai_mapped_stream_headers_written(mut state)!
			openai_write_sse_error(mut client_conn, 'openai_executor_error', mapping.error,
				'server_error')
			state.done = true
			return false
		}
		if mapping.content != '' || mapping.tool_calls.len > 0 {
			ensure_openai_mapped_stream_headers_written(mut state)!
			write_chunk(mut client_conn, 'data: ${openai_stream_chunk_json(state, mapping)}\n\n')!
		}
		openai_merge_usage(mut state.usage, mapping.usage)
		if mapping.done && !state.done {
			ensure_openai_mapped_stream_headers_written(mut state)!
			openai_write_stream_usage_chunk(mut state)!
			write_chunk(mut client_conn, 'data: [DONE]\n\n')!
			state.done = true
			openai_finish_mapped_stream(mut state)!
			return false
		}
		return true
	}) or {
		if !state.headers_written {
			state.status_code = 502
			ensure_openai_mapped_stream_headers_written(mut state) or {}
			openai_write_sse_error(mut client_conn, 'openai_executor_failed', err.msg(),
				'server_error')
			state.done = true
		}
		if state.headers_written {
			openai_finish_mapped_stream(mut state) or {}
		}
		client_conn.close() or {}
		app.emit('http.request', {
			'method':      method.to_upper()
			'path':        normalize_path(path)
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
		for mapping in openai_executor_stream_mappings(stream_resp.response.result) {
			if mapping.error != '' {
				ensure_openai_mapped_stream_headers_written(mut state) or {}
				openai_write_sse_error(mut client_conn, 'openai_executor_error', mapping.error,
					'server_error')
				state.done = true
				break
			}
			if mapping.content != '' || mapping.tool_calls.len > 0 {
				ensure_openai_mapped_stream_headers_written(mut state) or {}
				write_chunk(mut client_conn, 'data: ${openai_stream_chunk_json(state,
					mapping)}\n\n') or {}
			}
			openai_merge_usage(mut state.usage, mapping.usage)
			if mapping.done && !state.done {
				ensure_openai_mapped_stream_headers_written(mut state) or {}
				openai_write_stream_usage_chunk(mut state) or {}
				write_chunk(mut client_conn, 'data: [DONE]\n\n') or {}
				state.done = true
				openai_finish_mapped_stream(mut state) or {}
			}
		}
	}
	if !state.done {
		ensure_openai_mapped_stream_headers_written(mut state) or {}
		openai_write_stream_usage_chunk(mut state) or {}
		write_chunk(mut client_conn, 'data: [DONE]\n\n') or {}
	}
	if state.headers_written {
		openai_finish_mapped_stream(mut state) or {}
	}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        normalize_path(path)
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

fn (mut app App) openai_handle_models(mut ctx Context, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if method.to_upper() !in ['GET', 'HEAD'] {
		return openai_error(mut app, mut ctx, 405, path, method, req_id, trace_id, start_ms,
			'method_not_allowed', 'method ${method} is not allowed for ${path}')
	}
	models := if app.openai_plugin.trim_space() != '' {
		result := app.openai_plugin_models(method, path, req_id, trace_id) or {
			return openai_error(mut app, mut ctx, 500, path, method, req_id, trace_id,
				start_ms, 'plugin_error', err.msg())
		}
		if result.handled {
			result.models
		} else {
			app.openai_models()
		}
	} else {
		app.openai_models()
	}
	mut data := []OpenAIModelObject{}
	for model in models {
		data << OpenAIModelObject{
			id:      model
			created: int(app.started_at_unix)
		}
	}
	body := json.encode(OpenAIModelsResponse{
		data: data
	})
	ctx.res.set_status(.ok)
	ctx.set_content_type('application/json; charset=utf-8')
	ctx.set_custom_header('x-request-id', req_id) or {}
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        normalize_path(path)
		'status':      '200'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'provider':    'openai'
	})
	return ctx.text(if method.to_upper() == 'HEAD' { '' } else { body })
}

fn (mut app App) openai_handle_chat(mut ctx Context, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if method.to_upper() !in ['POST', 'HEAD'] {
		return openai_error(mut app, mut ctx, 405, path, method, req_id, trace_id, start_ms,
			'method_not_allowed', 'method ${method} is not allowed for ${path}')
	}
	model := openai_request_model(ctx.req.data)
	plan := app.openai_resolve_plan(model, ctx.req.data, method, path, req_id, trace_id) or {
		err_msg := err.msg()
		status := if err_msg.starts_with('openai_plugin_') { 502 } else { 400 }
		return openai_error(mut app, mut ctx, status, path, method, req_id, trace_id,
			start_ms, openai_plan_error_code(err_msg), openai_plan_error_message(err_msg))
	}
	if openai_is_stream_request(ctx.req.data) {
		if plan.backend.kind.trim_space() == 'executor' {
			return openai_proxy_executor_stream(mut app, mut ctx, plan, method, path,
				req_id, trace_id, start_ms)
		}
		if plan.stream_mode == 'mapped' {
			return openai_proxy_mapped_stream(mut app, mut ctx, plan, method, path, req_id,
				trace_id, start_ms)
		}
		return openai_proxy_stream(mut app, mut ctx, plan, method, path, req_id, trace_id,
			start_ms)
	}
	return openai_proxy_once(mut app, mut ctx, plan, method, path, req_id, trace_id, start_ms)
}

fn (mut app App) openai_handle_responses(mut ctx Context, method string, path string, req_id string, trace_id string, start_ms i64) veb.Result {
	if method.to_upper() !in ['POST', 'HEAD'] {
		return openai_error(mut app, mut ctx, 405, path, method, req_id, trace_id, start_ms,
			'method_not_allowed', 'method ${method} is not allowed for ${path}')
	}
	model := openai_request_model(ctx.req.data)
	plan := app.openai_resolve_responses_plan(model, ctx.req.data, method, path, req_id,
		trace_id) or {
		err_msg := err.msg()
		status := if err_msg.starts_with('openai_plugin_') { 502 } else { 400 }
		return openai_error(mut app, mut ctx, status, path, method, req_id, trace_id,
			start_ms, openai_plan_error_code(err_msg), openai_plan_error_message(err_msg))
	}
	if openai_is_stream_request(ctx.req.data) {
		if plan.backend.kind.trim_space() == 'executor' {
			return openai_proxy_responses_executor_stream(mut app, mut ctx, plan, method,
				path, req_id, trace_id, start_ms)
		}
		return openai_proxy_stream(mut app, mut ctx, plan, method, path, req_id, trace_id,
			start_ms)
	}
	if plan.backend.kind.trim_space() == 'executor' {
		return openai_proxy_responses_executor_once(mut app, mut ctx, plan, method, path,
			req_id, trace_id, start_ms)
	}
	return openai_proxy_once(mut app, mut ctx, plan, method, path, req_id, trace_id, start_ms)
}

fn (mut app App) openai_handle_responses_passthrough(mut ctx Context, method string, path string, relative_target string, req_id string, trace_id string, start_ms i64) veb.Result {
	if method.to_upper() !in ['GET', 'POST', 'DELETE', 'HEAD'] {
		return openai_error(mut app, mut ctx, 405, path, method, req_id, trace_id, start_ms,
			'method_not_allowed', 'method ${method} is not allowed for ${path}')
	}
	response_id := openai_response_id_from_relative(relative_target)
	relative_path := normalize_path(relative_target.all_before('?'))
	if method.to_upper() in ['GET', 'HEAD'] && response_id != ''
		&& !relative_path.contains('/input_items') {
		if record := app.openai_responses.get(response_id) {
			ctx.res.set_status(.ok)
			ctx.set_content_type('application/json; charset=utf-8')
			ctx.set_custom_header('x-request-id', req_id) or {}
			ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
			ctx.set_custom_header('x-vhttpd-openai-backend', record.backend_name) or {}
			app.emit('http.request', {
				'method':      method.to_upper()
				'path':        normalize_path(path)
				'status':      '200'
				'request_id':  req_id
				'trace_id':    trace_id
				'duration_ms': '${time.now().unix_milli() - start_ms}'
				'provider':    'openai'
				'backend':     record.backend_name
				'executor':    record.executor
				'endpoint':    'responses.registry'
			})
			return ctx.text(if method.to_upper() == 'HEAD' { '' } else { record.body })
		}
	}
	plan := app.openai_resolve_responses_passthrough_plan(relative_target, ctx.req.data,
		method) or {
		err_msg := err.msg()
		status := if err_msg.starts_with('openai_plugin_') { 502 } else { 400 }
		return openai_error(mut app, mut ctx, status, path, method, req_id, trace_id,
			start_ms, openai_plan_error_code(err_msg), openai_plan_error_message(err_msg))
	}
	if plan.backend.kind.trim_space() == 'executor' {
		return openai_error(mut app, mut ctx, 502, path, method, req_id, trace_id, start_ms,
			'unsupported_backend', 'Responses passthrough endpoint ${relative_target} requires an HTTP backend')
	}
	if openai_is_stream_request(ctx.req.data) || openai_is_stream_target(path) {
		return openai_proxy_stream(mut app, mut ctx, plan, method, path, req_id, trace_id,
			start_ms)
	}
	return openai_proxy_once_attempt(mut app, mut ctx, plan, method, path, req_id, trace_id,
		start_ms, false)
}

fn (mut app App) openai_try_handle(mut ctx Context, method string, target string, req_id string, trace_id string, start_ms i64) ?veb.Result {
	if !app.openai_enabled {
		return none
	}
	relative := openai_relative_path(target, app.openai_base_path) or { return none }
	relative_target := openai_relative_target(target, app.openai_base_path) or { return none }
	if relative == '/models' {
		if !app.openai_endpoints.models {
			return openai_error(mut app, mut ctx, 404, target, method, req_id, trace_id,
				start_ms, 'endpoint_disabled', 'OpenAI models endpoint is disabled')
		}
		return app.openai_handle_models(mut ctx, method, target, req_id, trace_id, start_ms)
	}
	if relative == '/chat/completions' {
		if !app.openai_endpoints.chat_completions {
			return openai_error(mut app, mut ctx, 404, target, method, req_id, trace_id,
				start_ms, 'endpoint_disabled', 'OpenAI chat completions endpoint is disabled')
		}
		return app.openai_handle_chat(mut ctx, method, target, req_id, trace_id, start_ms)
	}
	if relative == '/responses' {
		if !app.openai_endpoints.responses {
			return openai_error(mut app, mut ctx, 404, target, method, req_id, trace_id,
				start_ms, 'endpoint_disabled', 'OpenAI responses endpoint is disabled')
		}
		return app.openai_handle_responses(mut ctx, method, target, req_id, trace_id,
			start_ms)
	}
	if relative.starts_with('/responses/') {
		if !app.openai_endpoints.responses {
			return openai_error(mut app, mut ctx, 404, target, method, req_id, trace_id,
				start_ms, 'endpoint_disabled', 'OpenAI responses endpoint is disabled')
		}
		return app.openai_handle_responses_passthrough(mut ctx, method, target, relative_target,
			req_id, trace_id, start_ms)
	}
	if relative == '/embeddings' {
		return openai_error(mut app, mut ctx, 501, target, method, req_id, trace_id, start_ms,
			'endpoint_not_implemented', 'OpenAI endpoint ${relative} is not implemented yet')
	}
	return openai_error(mut app, mut ctx, 404, target, method, req_id, trace_id, start_ms,
		'endpoint_not_found', 'OpenAI endpoint ${relative} was not found')
}
