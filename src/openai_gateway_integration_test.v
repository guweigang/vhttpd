module main

import net
import net.http
import os
import time
import veb

fn openai_integration_free_port_pair() (int, int) {
	seed := int((time.now().unix_milli() + os.getpid()) % 10000)
	for i in 0 .. 1000 {
		port := 30000 + ((seed + i) % 20000)
		mut first := net.listen_tcp(.ip, '127.0.0.1:${port}') or { continue }
		mut second := net.listen_tcp(.ip, '127.0.0.1:${port + 1}') or {
			first.close() or {}
			continue
		}
		first.close() or {}
		second.close() or {}
		return port, port + 1
	}
	panic('openai integration could not find free TCP port pair')
}

fn openai_integration_wait_for_http(url string) {
	for _ in 0 .. 80 {
		http.fetch(url: url, method: .get) or {
			time.sleep(25 * time.millisecond)
			continue
		}
		return
	}
}

fn openai_integration_wait_for_file(path string) {
	for _ in 0 .. 80 {
		if os.exists(path) {
			return
		}
		time.sleep(25 * time.millisecond)
	}
}

fn openai_integration_read_http_request(mut conn net.TcpConn) string {
	mut raw := ''
	mut buf := []u8{len: 4096}
	for _ in 0 .. 80 {
		n := conn.read(mut buf) or { 0 }
		if n <= 0 {
			break
		}
		raw += buf[..n].bytestr()
		header := raw.all_before('\r\n\r\n')
		if header.len == raw.len {
			continue
		}
		mut content_length := 0
		for line in header.split('\r\n') {
			if line.to_lower().starts_with('content-length:') {
				content_length = line.all_after(':').trim_space().int()
			}
		}
		body_len := raw.len - header.len - 4
		if body_len >= content_length {
			break
		}
	}
	return raw
}

fn openai_integration_read_http_response_until(mut conn net.TcpConn, marker string) string {
	mut raw := ''
	mut buf := []u8{len: 4096}
	conn.set_read_timeout(2 * time.second)
	for _ in 0 .. 80 {
		n := conn.read(mut buf) or { 0 }
		if n <= 0 {
			break
		}
		raw += buf[..n].bytestr()
		if raw.contains(marker) {
			break
		}
	}
	return raw
}

fn openai_integration_mock_upstream(port int, mode string, request_log string, ready_file string) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { panic(err) }
	defer {
		listener.close() or {}
	}
	os.write_file(ready_file, 'ready') or {}
	mut conn := listener.accept() or { return }
	defer {
		conn.close() or {}
	}
	raw := openai_integration_read_http_request(mut conn)
	os.write_file(request_log, raw) or {}
	if mode == 'stream' {
		conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n') or {}
		conn.write_string('data: {"id":"chunk-1","choices":[{"delta":{"content":"hello"}}]}\n\n') or {}
		conn.write_string('data: [DONE]\n\n') or {}
		return
	}
	if mode == 'stream_keepalive_after_done' {
		conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: keep-alive\r\n\r\n') or {}
		conn.write_string('data: {"id":"chunk-keepalive","choices":[{"delta":{"content":"hello"}}]}\n\n') or {}
		conn.write_string('data: [DONE]\n\n') or {}
		time.sleep(6 * time.second)
		return
	}
	if mode == 'stream_chunked' {
		conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n') or {}
		frame1 := 'data: {"id":"chunked-1","choices":[{"delta":{"content":"hello"}}]}\n\n'
		frame2 := 'data: [DONE]\n\n'
		conn.write_string('${frame1.len:x}\r\n${frame1}\r\n') or {}
		conn.write_string('${frame2.len:x}\r\n${frame2}\r\n') or {}
		conn.write_string('0\r\n\r\n') or {}
		return
	}
	if mode == 'responses_stream' {
		conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n') or {}
		conn.write_string('event: response.created\ndata: {"type":"response.created","response":{"id":"resp_mock","object":"response","status":"in_progress"},"sequence_number":1}\n\n') or {}
		conn.write_string('event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"hello","sequence_number":2}\n\n') or {}
		conn.write_string('event: response.completed\ndata: {"type":"response.completed","response":{"id":"resp_mock","object":"response","status":"completed"},"sequence_number":3}\n\n') or {}
		return
	}
	if mode == 'responses_json' {
		conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n') or {}
		conn.write_string('{"id":"resp_mock","object":"response","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"response ok"}]}]}') or {}
		return
	}
	if mode == 'responses_stateful' {
		conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n') or {}
		if raw.starts_with('POST /v1/responses/resp_123/cancel HTTP/') {
			conn.write_string('{"id":"resp_123","object":"response","status":"cancelled"}') or {}
		} else {
			conn.write_string('{"id":"resp_123","object":"response","status":"completed"}') or {}
		}
		return
	}
	if mode == 'ollama_ndjson' {
		conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n') or {}
		conn.write_string('{"message":{"role":"assistant","content":"你"},"done":false}\n') or {}
		conn.write_string('{"message":{"role":"assistant","content":"好"},"done":false}\n') or {}
		conn.write_string('{"done":true}\n') or {}
		return
	}
	if mode == 'custom_ndjson' {
		conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n') or {}
		conn.write_string('{"delta":"plugin-","finished":false}\n') or {}
		conn.write_string('{"delta":"mapped","finished":false}\n') or {}
		conn.write_string('{"finished":true}\n') or {}
		return
	}
	if mode == 'tool_call_ndjson' {
		conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n') or {}
		conn.write_string('{"message":{"role":"assistant","tool_calls":[{"index":0,"id":"call_search","type":"function","function":{"name":"search","arguments":"{\\"q\\":\\"vh"}}]},"done":false}\n') or {}
		conn.write_string('{"message":{"role":"assistant","tool_calls":[{"index":0,"function":{"arguments":"ttpd\\"}"}}]},"done":false}\n') or {}
		conn.write_string('{"done":true}\n') or {}
		return
	}
	if mode == 'usage_ndjson' {
		conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n') or {}
		conn.write_string('{"message":{"role":"assistant","content":"usage ok"},"done":false}\n') or {}
		conn.write_string('{"done":true,"prompt_eval_count":5,"eval_count":9}\n') or {}
		return
	}
	if mode == 'json_error' {
		conn.write_string('HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n') or {}
		conn.write_string('{"error":{"message":"provider quota exceeded","type":"rate_limit_error","code":"rate_limit_exceeded"}}') or {}
		return
	}
	if mode == 'stream_error' {
		conn.write_string('HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n') or {}
		conn.write_string('{"error":{"message":"provider overloaded","type":"server_error","code":"provider_overloaded"}}') or {}
		return
	}
	conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n') or {}
	conn.write_string('{"id":"cmpl-mock","object":"chat.completion","choices":[{"message":{"role":"assistant","content":"ok"}}]}') or {}
}

fn openai_integration_mock_fallback_upstream(port int, request_log string, ready_file string) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { panic(err) }
	defer {
		listener.close() or {}
	}
	os.write_file(ready_file, 'ready') or {}
	mut first := listener.accept() or { return }
	raw_first := openai_integration_read_http_request(mut first)
	first.write_string('HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n') or {}
	first.write_string('{"error":{"message":"primary overloaded","type":"server_error","code":"primary_overloaded"}}') or {}
	first.close() or {}
	mut second := listener.accept() or { return }
	raw_second := openai_integration_read_http_request(mut second)
	os.write_file(request_log, raw_first + '\n---SECOND---\n' + raw_second) or {}
	if raw_second.starts_with('POST /v1/fallback/api/chat HTTP/') {
		second.write_string('HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n') or {}
		second.write_string('{"message":{"role":"assistant","content":"mapped "},"done":false}\n') or {}
		second.write_string('{"message":{"role":"assistant","content":"fallback"},"done":false}\n') or {}
		second.write_string('{"done":true}\n') or {}
		second.close() or {}
		return
	}
	if raw_second.starts_with('POST /v1/fallback/chat/completions HTTP/') {
		if raw_second.contains('"stream":true') {
			second.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n') or {}
			second.write_string('data: {"id":"chunk-fallback","choices":[{"delta":{"content":"fallback stream"}}]}\n\n') or {}
			second.write_string('data: [DONE]\n\n') or {}
			second.close() or {}
			return
		}
		second.write_string('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n') or {}
		second.write_string('{"id":"cmpl-fallback","object":"chat.completion","choices":[{"message":{"role":"assistant","content":"fallback ok"}}]}') or {}
		second.close() or {}
		return
	}
	second.write_string('HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n') or {}
	second.write_string('{"error":{"message":"fallback was not used","type":"server_error","code":"fallback_not_used"}}') or {}
	second.close() or {}
}

fn openai_integration_start_gateway(port int, upstream_port int, plugin_file string) {
	plugins := if plugin_file.trim_space() == '' {
		map[string]PluginConfig{}
	} else {
		{
			'planner': PluginConfig{
				kind:            'vjsx'
				app_entry:       plugin_file
				runtime_profile: 'node'
				thread_count:    1
			}
		}
	}
	mut app := App{
		event_log:                  ''
		started_at_unix:            time.now().unix()
		openai_enabled:             true
		openai_base_path:           '/v1'
		openai_plugin:              if plugin_file.trim_space() == '' { '' } else { 'planner' }
		openai_default_backend:     'mock'
		openai_endpoints:           OpenAIEndpointsConfig{}
		openai_backends:            {
			'mock':   OpenAIBackendConfig{
				base_url: 'http://127.0.0.1:${upstream_port}/v1'
			}
			'backup': OpenAIBackendConfig{
				base_url: 'http://127.0.0.1:${upstream_port}/v1'
			}
			'exec':   OpenAIBackendConfig{
				kind:     'executor'
				executor: 'planner'
			}
		}
		openai_routes:              {
			'public': OpenAIRouteConfig{
				models:         ['public-model']
				backend:        'mock'
				upstream_model: 'builtin-upstream-model'
			}
		}
		plugin_configs:             plugins
		plugin_vjsx:                build_vjsx_plugin_runtimes(plugins)
		openai_responses:           new_memory_state_store[OpenAIResponseRecord]()
		upstream_sessions:          map[string]UpstreamRuntimeSession{}
		mcp_sessions:               map[string]McpSession{}
		ws_hub_conns:               map[string]HubConn{}
		ws_hub_room_members:        map[string]map[string]bool{}
		ws_hub_conn_rooms:          map[string]map[string]bool{}
		ws_hub_conn_meta:           map[string]map[string]string{}
		ws_hub_pending:             map[string][]HubPendingMessage{}
		feishu_runtime:             map[string]FeishuProviderRuntime{}
		websocket_upstream_started: map[string]bool{}
		providers:                  ProviderHost{
			registry: map[string]Provider{}
			specs:    map[string]ProviderSpec{}
		}
		fixture_websocket_runtime:  map[string]FixtureWebSocketUpstreamRuntime{}
		provider_instance_specs:    map[string]ProviderInstanceSpec{}
		codex_instances:            map[string]CodexProviderRuntime{}
		feishu_buffers:             map[string]FeishuStreamBuffer{}
	}
	veb.run_at[App, Context](mut app,
		host:                 '127.0.0.1'
		port:                 port
		family:               .ip
		show_startup_message: false
	) or {}
}

fn openai_integration_write_plugin(temp_dir string) string {
	plugin_file := os.join_path(temp_dir, 'openai-planner.mts')
	os.write_file(plugin_file, "
export function openai(req) {
  if (req.op !== 'chat.route') return { not_handled: true };
  const payload = JSON.parse(req.payload);
  const body = JSON.parse(payload.body);
  body.model = 'plugin-upstream-model';
  return {
    backend: 'mock',
    method: 'POST',
    path: '/chat/completions',
    headers: { 'x-plugin-plan': 'yes' },
    body: JSON.stringify(body),
    stream_mode: 'passthrough',
  };
}
") or {
		panic(err)
	}
	return plugin_file
}

fn openai_integration_write_bad_plugin(temp_dir string) string {
	plugin_file := os.join_path(temp_dir, 'openai-bad-planner.mts')
	os.write_file(plugin_file, "
export function openai(req) {
  if (req.op !== 'chat.route') return { not_handled: true };
  return {
    backend: 'mock',
    method: 'TRACE',
    path: '/chat/completions',
    body: '{}',
    stream_mode: 'passthrough',
  };
}
") or {
		panic(err)
	}
	return plugin_file
}

fn openai_integration_write_ollama_plugin(temp_dir string) string {
	plugin_file := os.join_path(temp_dir, 'openai-ollama-planner.mts')
	os.write_file(plugin_file, "
export function openai(req) {
  if (req.op !== 'chat.route') return { not_handled: true };
  const payload = JSON.parse(req.payload);
  const body = JSON.parse(payload.body);
  return {
    backend: 'mock',
    method: 'POST',
    path: '/api/chat',
    headers: { 'x-plugin-plan': 'ollama' },
    body: JSON.stringify({
      model: 'qwen2.5',
      messages: body.messages,
      stream: body.stream === true,
    }),
    stream_mode: 'mapped',
    response_codec: 'ndjson',
    output_protocol: 'openai.chat.completion',
  };
}
") or {
		panic(err)
	}
	return plugin_file
}

fn openai_integration_write_tool_call_plugin(temp_dir string) string {
	plugin_file := os.join_path(temp_dir, 'openai-tool-call-planner.mts')
	os.write_file(plugin_file, "
export function openai(req) {
  if (req.op !== 'chat.route') return { not_handled: true };
  return {
    backend: 'mock',
    method: 'POST',
    path: '/api/chat',
    body: JSON.stringify({ stream: true }),
    stream_mode: 'mapped',
    response_codec: 'ndjson',
    output_protocol: 'openai.chat.completion',
  };
}
") or {
		panic(err)
	}
	return plugin_file
}

fn openai_integration_write_usage_plugin(temp_dir string) string {
	plugin_file := os.join_path(temp_dir, 'openai-usage-planner.mts')
	os.write_file(plugin_file, "
export function openai(req) {
  if (req.op !== 'chat.route') return { not_handled: true };
  return {
    backend: 'mock',
    method: 'POST',
    path: '/api/chat',
    body: JSON.stringify({ stream: false }),
    stream_mode: 'mapped',
    response_codec: 'ndjson',
    output_protocol: 'openai.chat.completion',
  };
}
") or {
		panic(err)
	}
	return plugin_file
}

fn openai_integration_write_executor_plugin(temp_dir string) string {
	plugin_file := os.join_path(temp_dir, 'openai-executor-planner.mts')
	os.write_file(plugin_file, "
async function* executorFrames(body) {
  yield { content: 'executor ', done: false };
  yield { content: body.messages?.[0]?.content ?? 'ok', done: false };
  yield { usage: { prompt_tokens: 3, completion_tokens: 4, total_tokens: 7 }, done: true };
}

async function* responseEvents(body) {
  const input = Array.isArray(body.input) ? body.input.map((item) => item.content || '').join(' ') : String(body.input || 'ok');
  yield { type: 'response.created', response: { id: 'resp_exec', object: 'response', status: 'in_progress' }, sequence_number: 1 };
  yield { type: 'response.output_text.delta', delta: 'executor ' + input, sequence_number: 2 };
  yield { type: 'response.completed', response: { id: 'resp_exec', object: 'response', status: 'completed' }, sequence_number: 3 };
}

export function openai(req) {
  if (req.op === 'chat.route') {
    return {
      backend: 'exec',
      method: 'POST',
      path: '/executor/chat',
      body: JSON.parse(req.payload).body,
      stream_mode: 'executor',
    };
  }
  if (req.op === 'responses.route') {
    return {
      backend: 'exec',
      method: 'POST',
      path: '/executor/responses',
      body: JSON.parse(req.payload).body,
      stream_mode: 'executor',
      output_protocol: 'openai.response',
    };
  }
  if (req.op === 'chat.execute') {
    const payload = JSON.parse(req.payload);
    const body = JSON.parse(payload.body);
    if (payload.stream) {
      return executorFrames(body);
    }
    return {
      content: 'executor ' + (body.messages?.[0]?.content ?? 'ok'),
      usage: { prompt_tokens: 3, completion_tokens: 4, total_tokens: 7 },
      done: true,
    };
  }
  if (req.op === 'responses.execute') {
    const payload = JSON.parse(req.payload);
    const body = JSON.parse(payload.body);
    const input = Array.isArray(body.input) ? body.input.map((item) => item.content || '').join(' ') : String(body.input || 'ok');
    if (payload.stream) {
      return responseEvents(body);
    }
    return {
      id: 'resp_exec',
      object: 'response',
      status: 'completed',
      output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'executor ' + input }] }],
    };
  }
  return { not_handled: true };
}
") or {
		panic(err)
	}
	return plugin_file
}

fn openai_integration_write_frame_mapper_plugin(temp_dir string) string {
	plugin_file := os.join_path(temp_dir, 'openai-frame-mapper.mts')
	os.write_file(plugin_file, "
export function openai(req) {
  if (req.op === 'chat.route') {
    const payload = JSON.parse(req.payload);
    const body = JSON.parse(payload.body);
    return {
      backend: 'mock',
      method: 'POST',
      path: '/custom/stream',
      body: JSON.stringify({ prompt: body.messages?.[0]?.content ?? '', stream: true }),
      stream_mode: 'mapped',
      response_codec: 'ndjson',
      output_protocol: 'openai.chat.completion',
      mapper: 'plugin',
    };
  }
  if (req.op === 'chat.map_frame') {
    const payload = JSON.parse(req.payload);
    const frame = JSON.parse(payload.frame);
    return {
      content: frame.delta ? frame.delta.toUpperCase() : '',
      done: frame.finished === true,
    };
  }
  return { not_handled: true };
}
") or {
		panic(err)
	}
	return plugin_file
}

fn openai_integration_write_plugin_tool_call_mapper(temp_dir string) string {
	plugin_file := os.join_path(temp_dir, 'openai-plugin-tool-call-mapper.mts')
	os.write_file(plugin_file, "
export function openai(req) {
  if (req.op === 'chat.route') {
    return {
      backend: 'mock',
      method: 'POST',
      path: '/custom/stream',
      body: JSON.stringify({ stream: true }),
      stream_mode: 'mapped',
      response_codec: 'ndjson',
      output_protocol: 'openai.chat.completion',
      mapper: 'plugin',
    };
  }
  if (req.op === 'chat.map_frame') {
    const payload = JSON.parse(req.payload);
    const frame = JSON.parse(payload.frame);
    if (frame.finished) return { done: true };
    return {
      tool_calls: [{
        index: 0,
        id: 'call_plugin',
        type: 'function',
        function: { name: 'lookup', arguments: frame.delta },
      }],
      finish_reason: 'tool_calls',
    };
  }
  return { not_handled: true };
}
") or {
		panic(err)
	}
	return plugin_file
}

fn openai_integration_write_mapper_error_plugin(temp_dir string) string {
	plugin_file := os.join_path(temp_dir, 'openai-mapper-error.mts')
	os.write_file(plugin_file, "
export function openai(req) {
  if (req.op === 'chat.route') {
    return {
      backend: 'mock',
      method: 'POST',
      path: '/custom/stream',
      body: JSON.stringify({ stream: true }),
      stream_mode: 'mapped',
      response_codec: 'ndjson',
      output_protocol: 'openai.chat.completion',
      mapper: 'plugin',
    };
  }
  if (req.op === 'chat.map_frame') {
    return { error: { message: 'mapper refused frame' } };
  }
  return { not_handled: true };
}
") or {
		panic(err)
	}
	return plugin_file
}

fn openai_integration_write_fallback_plugin(temp_dir string) string {
	plugin_file := os.join_path(temp_dir, 'openai-fallback-planner.mts')
	os.write_file(plugin_file, "
export function openai(req) {
  if (req.op === 'chat.route') {
    const payload = JSON.parse(req.payload);
    return {
      backend: 'mock',
      method: 'POST',
      path: '/primary/chat/completions',
      body: payload.body,
      stream_mode: 'passthrough',
    };
  }
  if (req.op === 'chat.fallback') {
    const payload = JSON.parse(req.payload);
    if (payload.failed_backend !== 'mock' || payload.status_code !== 503) {
      return { not_handled: true };
    }
    return {
      backend: 'backup',
      method: 'POST',
      path: '/fallback/chat/completions',
      body: payload.body,
      stream_mode: 'passthrough',
    };
  }
  return { not_handled: true };
}
") or {
		panic(err)
	}
	return plugin_file
}

fn openai_integration_write_mapped_fallback_plugin(temp_dir string) string {
	plugin_file := os.join_path(temp_dir, 'openai-mapped-fallback-planner.mts')
	os.write_file(plugin_file, "
export function openai(req) {
  if (req.op === 'chat.route') {
    const payload = JSON.parse(req.payload);
    const body = JSON.parse(payload.body);
    return {
      backend: 'mock',
      method: 'POST',
      path: '/primary/api/chat',
      body: JSON.stringify({ model: 'primary-local', messages: body.messages, stream: true }),
      stream_mode: 'mapped',
      response_codec: 'ndjson',
      output_protocol: 'openai.chat.completion',
    };
  }
  if (req.op === 'chat.fallback') {
    const payload = JSON.parse(req.payload);
    if (payload.failed_backend !== 'mock' || payload.status_code !== 503) {
      return { not_handled: true };
    }
    return {
      backend: 'backup',
      method: 'POST',
      path: '/fallback/api/chat',
      body: JSON.stringify({ model: 'backup-local', stream: true }),
      stream_mode: 'mapped',
      response_codec: 'ndjson',
      output_protocol: 'openai.chat.completion',
    };
  }
  return { not_handled: true };
}
") or {
		panic(err)
	}
	return plugin_file
}

fn test_openai_gateway_plugin_non_stream_passthrough_hits_mock_upstream() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_non_stream_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	plugin_file := openai_integration_write_plugin(temp_dir)
	spawn openai_integration_mock_upstream(upstream_port, 'json', request_log, ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","messages":[{"role":"user","content":"hi"}]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"cmpl-mock"')
	raw := os.read_file(request_log) or { panic(err) }
	assert raw.starts_with('POST /v1/chat/completions HTTP/')
	assert raw.to_lower().contains('x-plugin-plan: yes')
	assert raw.contains('"model":"plugin-upstream-model"')
}

fn test_openai_gateway_stream_passthrough_forwards_sse_bytes() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_stream_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	spawn openai_integration_mock_upstream(upstream_port, 'stream', request_log, ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, '')
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"messages":[{"role":"user","content":"hi"}]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('data: {"id":"chunk-1"')
	assert resp.body.contains('data: [DONE]')
	raw := os.read_file(request_log) or { panic(err) }
	assert raw.contains('"model":"builtin-upstream-model"')
	assert raw.contains('"stream":true')
}

fn test_openai_gateway_stream_passthrough_dechunks_upstream_sse() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_stream_chunked_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	spawn openai_integration_mock_upstream(upstream_port, 'stream_chunked', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, '')
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"messages":[{"role":"user","content":"hi"}]}'
	) or { panic(err) }
	frame1 := 'data: {"id":"chunked-1","choices":[{"delta":{"content":"hello"}}]}\n\n'
	frame2 := 'data: [DONE]\n\n'
	assert resp.status_code == 200
	assert resp.body.contains(frame1)
	assert resp.body.contains(frame2)
	assert !resp.body.contains('${frame1.len:x}\r\n')
	assert !resp.body.contains('${frame2.len:x}\r\n')
	assert !resp.body.contains('\r\n0\r\n')
}

fn test_openai_gateway_stream_passthrough_writes_chunked_response_boundary() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_stream_response_chunked_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	spawn openai_integration_mock_upstream(upstream_port, 'stream', request_log, ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, '')
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	body := '{"model":"public-model","stream":true,"messages":[{"role":"user","content":"hi"}]}'
	mut conn := net.dial_tcp('127.0.0.1:${gateway_port}') or { panic(err) }
	defer {
		conn.close() or {}
	}
	conn.write_string('POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:${gateway_port}\r\nContent-Type: application/json\r\nAccept: text/event-stream\r\nContent-Length: ${body.len}\r\n\r\n${body}') or {
		panic(err)
	}
	raw := openai_integration_read_http_response_until(mut conn, '\r\n0\r\n\r\n')
	assert raw.starts_with('HTTP/1.1 200 OK')
	assert raw.to_lower().contains('transfer-encoding: chunked')
	assert !raw.to_lower().contains('connection: close')
	assert raw.contains('data: {"id":"chunk-1"')
	assert raw.contains('data: [DONE]')
	assert raw.contains('\r\n0\r\n\r\n')
	conn.write_string('GET /health HTTP/1.1\r\nHost: 127.0.0.1:${gateway_port}\r\n\r\n') or {
		panic(err)
	}
	second := openai_integration_read_http_response_until(mut conn, '\r\n\r\nOK')
	assert second.starts_with('HTTP/1.1 200 OK')
	assert second.ends_with('\r\n\r\nOK')
}

fn test_openai_gateway_stream_passthrough_finishes_on_done_before_upstream_close() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_stream_done_boundary_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	spawn openai_integration_mock_upstream(upstream_port, 'stream_keepalive_after_done',
		request_log, ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, '')
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	body := '{"model":"public-model","stream":true,"messages":[{"role":"user","content":"hi"}]}'
	mut conn := net.dial_tcp('127.0.0.1:${gateway_port}') or { panic(err) }
	defer {
		conn.close() or {}
	}
	conn.write_string('POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:${gateway_port}\r\nContent-Type: application/json\r\nAccept: text/event-stream\r\nContent-Length: ${body.len}\r\n\r\n${body}') or {
		panic(err)
	}
	raw := openai_integration_read_http_response_until(mut conn, '\r\n0\r\n\r\n')
	assert raw.starts_with('HTTP/1.1 200 OK')
	assert raw.to_lower().contains('transfer-encoding: chunked')
	assert raw.contains('data: {"id":"chunk-keepalive"')
	assert raw.contains('data: [DONE]')
	assert raw.contains('\r\n0\r\n\r\n')
}

fn test_openai_gateway_mapped_ollama_ndjson_stream_outputs_openai_sse() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_ollama_stream_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	plugin_file := openai_integration_write_ollama_plugin(temp_dir)
	spawn openai_integration_mock_upstream(upstream_port, 'ollama_ndjson', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"messages":[{"role":"user","content":"hi"}]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('data: {"id":"chatcmpl-')
	assert resp.body.contains('"object":"chat.completion.chunk"')
	assert resp.body.contains('"content":"你"')
	assert resp.body.contains('"content":"好"')
	assert resp.body.contains('data: [DONE]')
	raw := os.read_file(request_log) or { panic(err) }
	assert raw.starts_with('POST /v1/api/chat HTTP/')
	assert raw.to_lower().contains('x-plugin-plan: ollama')
	assert raw.contains('"model":"qwen2.5"')
	assert raw.contains('"stream":true')
}

fn test_openai_gateway_mapped_ndjson_tool_calls_output_openai_delta() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_tool_call_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	plugin_file := openai_integration_write_tool_call_plugin(temp_dir)
	spawn openai_integration_mock_upstream(upstream_port, 'tool_call_ndjson', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"messages":[]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"tool_calls"')
	assert resp.body.contains('"id":"call_search"')
	assert resp.body.contains('"name":"search"')
	assert resp.body.contains('"arguments":"{\\"q\\":\\"vh"')
	assert resp.body.contains('"arguments":"ttpd\\"}"')
	assert resp.body.contains('"finish_reason":"tool_calls"')
	assert resp.body.contains('data: [DONE]')
}

fn test_openai_gateway_mapped_ndjson_tool_calls_aggregate_non_stream() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_tool_call_once_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	plugin_file := openai_integration_write_tool_call_plugin(temp_dir)
	spawn openai_integration_mock_upstream(upstream_port, 'tool_call_ndjson', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":false,"messages":[]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"object":"chat.completion"')
	assert resp.body.contains('"message"')
	assert resp.body.contains('"tool_calls"')
	assert resp.body.contains('"id":"call_search"')
	assert resp.body.contains('"name":"search"')
	assert resp.body.contains('"arguments":"{\\"q\\":\\"vhttpd\\"}"')
	assert resp.body.contains('"finish_reason":"tool_calls"')
	assert !resp.body.contains('data:')
}

fn test_openai_gateway_mapped_ndjson_usage_aggregates_non_stream() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_usage_once_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	plugin_file := openai_integration_write_usage_plugin(temp_dir)
	spawn openai_integration_mock_upstream(upstream_port, 'usage_ndjson', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":false,"messages":[]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"content":"usage ok"')
	assert resp.body.contains('"usage"')
	assert resp.body.contains('"prompt_tokens":5')
	assert resp.body.contains('"completion_tokens":9')
	assert resp.body.contains('"total_tokens":14')
	assert !resp.body.contains('data:')
}

fn test_openai_gateway_mapped_ndjson_usage_outputs_stream_final_chunk() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_usage_stream_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	plugin_file := openai_integration_write_usage_plugin(temp_dir)
	spawn openai_integration_mock_upstream(upstream_port, 'usage_ndjson', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"messages":[]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"content":"usage ok"')
	assert resp.body.contains('"choices":[]')
	assert resp.body.contains('"usage"')
	assert resp.body.contains('"prompt_tokens":5')
	assert resp.body.contains('"completion_tokens":9')
	assert resp.body.contains('"total_tokens":14')
	assert resp.body.contains('data: [DONE]')
	assert resp.body.index('"usage"') or { -1 } < resp.body.index('data: [DONE]') or { -1 }
}

fn test_openai_gateway_executor_backend_non_stream_uses_vjsx_app() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_executor_once_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	plugin_file := openai_integration_write_executor_plugin(temp_dir)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","messages":[{"role":"user","content":"handled"}]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"object":"chat.completion"')
	assert resp.body.contains('"content":"executor handled"')
	assert resp.body.contains('"usage"')
	assert resp.body.contains('"total_tokens":7')
}

fn test_openai_gateway_executor_backend_stream_uses_vjsx_frames() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_executor_stream_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	plugin_file := openai_integration_write_executor_plugin(temp_dir)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"messages":[{"role":"user","content":"stream"}]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"content":"executor "')
	assert resp.body.contains('"content":"stream"')
	assert resp.body.contains('"choices":[]')
	assert resp.body.contains('"total_tokens":7')
	assert resp.body.contains('data: [DONE]')
}

fn test_openai_gateway_responses_passthrough_non_stream() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_responses_once_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	spawn openai_integration_mock_upstream(upstream_port, 'responses_json', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, '')
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/responses'
		method: .post
		header: header
		data:   '{"model":"public-model","input":"hello"}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"object":"response"')
	assert resp.body.contains('response ok')
	raw := os.read_file(request_log) or { panic(err) }
	assert raw.starts_with('POST /v1/responses HTTP/')
	assert raw.contains('"model":"builtin-upstream-model"')
}

fn test_openai_gateway_responses_passthrough_stream() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_responses_stream_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	spawn openai_integration_mock_upstream(upstream_port, 'responses_stream', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, '')
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/responses'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"input":"hello"}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('event: response.created')
	assert resp.body.contains('response.output_text.delta')
	assert resp.body.contains('response.completed')
	raw := os.read_file(request_log) or { panic(err) }
	assert raw.starts_with('POST /v1/responses HTTP/')
}

fn test_openai_gateway_responses_executor_stream_uses_async_iterable_events() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_responses_executor_stream_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	plugin_file := openai_integration_write_executor_plugin(temp_dir)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/responses'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"input":"stream"}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('event: response.created')
	assert resp.body.contains('response.output_text.delta')
	assert resp.body.contains('executor stream')
	assert resp.body.contains('response.completed')
}

fn test_openai_gateway_responses_executor_non_stream_registers_response() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_responses_executor_registry_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	plugin_file := openai_integration_write_executor_plugin(temp_dir)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	create_resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/responses'
		method: .post
		header: header
		data:   '{"model":"public-model","input":"remember me"}'
	) or { panic(err) }
	assert create_resp.status_code == 200
	assert create_resp.body.contains('"id":"resp_exec"')
	retrieve_resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/responses/resp_exec'
		method: .get
	) or { panic(err) }
	assert retrieve_resp.status_code == 200
	assert retrieve_resp.body.contains('"id":"resp_exec"')
	assert retrieve_resp.body.contains('executor remember me')
}

fn test_openai_gateway_responses_executor_stream_registers_completed_response() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_responses_executor_stream_registry_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	plugin_file := openai_integration_write_executor_plugin(temp_dir)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	stream_resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/responses'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"input":"stream"}'
	) or { panic(err) }
	assert stream_resp.status_code == 200
	assert stream_resp.body.contains('response.completed')
	retrieve_resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/responses/resp_exec'
		method: .get
	) or { panic(err) }
	assert retrieve_resp.status_code == 200
	assert retrieve_resp.body.contains('"id":"resp_exec"')
	assert retrieve_resp.body.contains('"status":"completed"')
}

fn test_openai_gateway_responses_retrieve_preserves_query() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_responses_retrieve_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	spawn openai_integration_mock_upstream(upstream_port, 'responses_stateful', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, '')
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/responses/resp_123?include[]=output_text'
		method: .get
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"id":"resp_123"')
	raw := os.read_file(request_log) or { panic(err) }
	assert raw.starts_with('GET /v1/responses/resp_123?include%5B%5D=output_text HTTP/')
}

fn test_openai_gateway_responses_cancel_passthrough() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_responses_cancel_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	spawn openai_integration_mock_upstream(upstream_port, 'responses_stateful', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, '')
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/responses/resp_123/cancel'
		method: .post
		data:   '{}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"status":"cancelled"')
	raw := os.read_file(request_log) or { panic(err) }
	assert raw.starts_with('POST /v1/responses/resp_123/cancel HTTP/')
}

fn test_openai_gateway_plugin_frame_mapper_outputs_openai_sse() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_plugin_mapper_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	plugin_file := openai_integration_write_frame_mapper_plugin(temp_dir)
	spawn openai_integration_mock_upstream(upstream_port, 'custom_ndjson', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"messages":[{"role":"user","content":"hi"}]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"content":"PLUGIN-"')
	assert resp.body.contains('"content":"MAPPED"')
	assert resp.body.contains('data: [DONE]')
	raw := os.read_file(request_log) or { panic(err) }
	assert raw.starts_with('POST /v1/custom/stream HTTP/')
	assert raw.contains('"prompt":"hi"')
}

fn test_openai_gateway_plugin_frame_mapper_can_emit_tool_calls() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_plugin_tool_call_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	plugin_file := openai_integration_write_plugin_tool_call_mapper(temp_dir)
	spawn openai_integration_mock_upstream(upstream_port, 'custom_ndjson', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"messages":[]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"tool_calls"')
	assert resp.body.contains('"id":"call_plugin"')
	assert resp.body.contains('"name":"lookup"')
	assert resp.body.contains('"arguments":"plugin-"')
	assert resp.body.contains('"arguments":"mapped"')
	assert resp.body.contains('"finish_reason":"tool_calls"')
	assert resp.body.contains('data: [DONE]')
}

fn test_openai_gateway_non_stream_upstream_error_is_openai_error() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_json_error_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	spawn openai_integration_mock_upstream(upstream_port, 'json_error', request_log, ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, '')
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","messages":[]}'
	) or { panic(err) }
	assert resp.status_code == 429
	assert resp.body.contains('"message":"provider quota exceeded"')
	assert resp.body.contains('"type":"rate_limit_error"')
	assert resp.body.contains('"code":"rate_limit_exceeded"')
}

fn test_openai_gateway_non_stream_plugin_fallback_retries_backup_plan() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_fallback_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	plugin_file := openai_integration_write_fallback_plugin(temp_dir)
	spawn openai_integration_mock_fallback_upstream(upstream_port, request_log, ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","messages":[]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"cmpl-fallback"')
	assert resp.body.contains('fallback ok')
	raw := os.read_file(request_log) or { panic(err) }
	assert raw.contains('POST /v1/primary/chat/completions HTTP/')
	assert raw.contains('POST /v1/fallback/chat/completions HTTP/')
}

fn test_openai_gateway_stream_plugin_fallback_retries_before_sse_headers() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_stream_fallback_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	plugin_file := openai_integration_write_fallback_plugin(temp_dir)
	spawn openai_integration_mock_fallback_upstream(upstream_port, request_log, ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"messages":[]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('data: {"id":"chunk-fallback"')
	assert resp.body.contains('fallback stream')
	assert resp.body.contains('data: [DONE]')
	raw := os.read_file(request_log) or { panic(err) }
	assert raw.contains('POST /v1/primary/chat/completions HTTP/')
	assert raw.contains('POST /v1/fallback/chat/completions HTTP/')
}

fn test_openai_gateway_mapped_stream_plugin_fallback_retries_before_sse_headers() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_mapped_fallback_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	plugin_file := openai_integration_write_mapped_fallback_plugin(temp_dir)
	spawn openai_integration_mock_fallback_upstream(upstream_port, request_log, ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"messages":[{"role":"user","content":"hi"}]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"object":"chat.completion.chunk"')
	assert resp.body.contains('"content":"mapped "')
	assert resp.body.contains('"content":"fallback"')
	assert resp.body.contains('data: [DONE]')
	raw := os.read_file(request_log) or { panic(err) }
	assert raw.contains('POST /v1/primary/api/chat HTTP/')
	assert raw.contains('POST /v1/fallback/api/chat HTTP/')
}

fn test_openai_gateway_stream_upstream_error_is_openai_error() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_stream_error_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	spawn openai_integration_mock_upstream(upstream_port, 'stream_error', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, '')
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"messages":[]}'
	) or { panic(err) }
	assert resp.status_code == 503
	assert resp.body.contains('"message":"provider overloaded"')
	assert resp.body.contains('"code":"provider_overloaded"')
	assert !resp.body.contains('data:')
}

fn test_openai_gateway_plugin_mapper_error_is_openai_sse_error() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_mapper_error_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	request_log := os.join_path(temp_dir, 'upstream.request.txt')
	ready_file := os.join_path(temp_dir, 'upstream.ready')
	plugin_file := openai_integration_write_mapper_error_plugin(temp_dir)
	spawn openai_integration_mock_upstream(upstream_port, 'custom_ndjson', request_log,
		ready_file)
	openai_integration_wait_for_file(ready_file)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	header.add(.accept, 'text/event-stream')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","stream":true,"messages":[]}'
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('data: {"error":')
	assert resp.body.contains('"message":"mapper refused frame"')
	assert resp.body.contains('"code":"mapper_error"')
	assert resp.body.contains('data: [DONE]')
}

fn test_openai_gateway_invalid_plugin_plan_returns_openai_error() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_gateway_bad_plan_integration_test')
	os.rmdir_all(temp_dir) or {}
	os.mkdir_all(temp_dir) or { panic(err) }
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	upstream_port, gateway_port := openai_integration_free_port_pair()
	plugin_file := openai_integration_write_bad_plugin(temp_dir)
	spawn openai_integration_start_gateway(gateway_port, upstream_port, plugin_file)
	openai_integration_wait_for_http('http://127.0.0.1:${gateway_port}/health')
	mut header := http.new_header()
	header.add(.content_type, 'application/json')
	resp := http.fetch(
		url:    'http://127.0.0.1:${gateway_port}/v1/chat/completions'
		method: .post
		header: header
		data:   '{"model":"public-model","messages":[]}'
	) or { panic(err) }
	assert resp.status_code == 502
	assert resp.body.contains('"code":"openai_plugin_plan_invalid_method"')
	assert resp.body.contains('unsupported upstream method TRACE')
}
