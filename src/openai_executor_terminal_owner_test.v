module main

import api.openai
import config
import net
import os
import rand
import time

const executor_terminal_source = '
let continued = false;
let closed = false;
const mode = "__MODE__";
export function openai(req) {
  if (req.op === "probe") return { continued, closed };
  if (mode.endsWith("batch")) return { frames: [
    { content: "first" }, { content: "final", done: true },
    { content: "late", done: true }
  ] };
  return (async function* () {
    try {
      if (mode === "chat_stream") yield { content: "final", done: true };
      else if (mode === "natural") yield { type: "response.output_text.delta", delta: "first" };
      else yield { type: "response." + mode,
        response: { id: "resp_terminal", object: "response", status: mode, model: "test" } };
      continued = true;
      if (mode !== "natural") yield { type: "response.output_text.delta", delta: "late" };
    } finally { closed = true; }
  })();
}
'

fn executor_terminal_check(mode string) {
	dir := os.join_path(os.temp_dir(), 'vhttpd-executor-terminal-${rand.uuid_v4()}')
	os.mkdir_all(dir) or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	entry := os.join_path(dir, 'executor.mjs')
	os.write_file(entry, executor_terminal_source.replace('__MODE__', mode)) or { panic(err) }
	mut app := &App{}
	app.protocols.plugins.publish({
		'executor': config.PluginConfig{
			kind:            'vjsx'
			app_entry:       entry
			module_root:     dir
			build_root:      os.join_path(dir, 'build')
			runtime_profile: 'node'
			thread_count:    1
		}
	})
	defer { app.close_all_plugins() }
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(address.str()) or { panic(err) }
	defer { peer.close() or {} }
	peer.set_read_timeout(100 * time.millisecond)
	mut server := listener.accept() or { panic(err) }
	defer { server.close() or {} }
	mut ctx := Context{}
	ctx.conn = server
	plan := openai.OpenAIResolvedPlan{
		backend_name: 'test'
		backend:      config.OpenAIBackendConfig{ kind: 'executor', executor: 'executor' }
		model:        'test'
		body:         '{"stream":true}'
	}
	if mode.starts_with('chat') {
		OpenAIProxyRuntime.executor_stream(mut app, mut ctx, plan, 'POST', '/chat', 'terminal', 'trace', 0)
	} else {
		OpenAIProxyRuntime.responses_executor_stream(mut app, mut ctx, plan, 'POST', '/responses', 'terminal', 'trace', 0)
	}
	mut body := ''
	mut buffer := []u8{len: 4096}
	for {
		n := peer.read(mut buffer) or { break }
		if n == 0 { break }
		body += buffer[..n].bytestr()
	}
	assert !body.contains('late'), body
	assert body.ends_with('0\r\n\r\n'), body
	if mode == 'chat_batch' {
		assert body.contains('first')
		assert body.contains('final')
		assert body.count('data: [DONE]') == 1
	} else if mode == 'responses_batch' {
		assert body.contains('first')
		assert body.contains('final')
		assert body.count('event: response.completed') == 1
	} else {
		probe := app.call_plugin(PluginCallRequest{ plugin: 'executor', capability: 'openai', op: 'probe' }) or { panic(err) }
		assert probe.result.contains('"closed":true'), probe.result
		assert probe.result.contains('"continued":${mode == 'natural'}'), probe.result
		if mode == 'completed' {
			assert body.count('event: response.completed') == 1
			stored := app.protocols.openai.responses.get('resp_terminal') or { panic('completed response not cached') }
			assert stored.body.contains('"status":"completed"')
		} else if mode in ['failed', 'incomplete'] {
			assert body.count('event: response.${mode}') == 1
			assert app.protocols.openai.responses.get('resp_terminal') == none
		} else if mode == 'natural' {
			assert body.contains('first')
		}
	}
}

fn test_chat_executor_batch_stops_after_done() { executor_terminal_check('chat_batch') }

fn test_responses_executor_batch_stops_after_done() { executor_terminal_check('responses_batch') }

fn test_responses_completed_cancels_generator_and_caches_completion() {
	executor_terminal_check('completed')
}

fn test_responses_failed_cancels_generator_without_cache() { executor_terminal_check('failed') }

fn test_responses_incomplete_cancels_generator_without_cache() {
	executor_terminal_check('incomplete')
}

fn test_chat_executor_terminal_generator_cleanup_is_preserved() {
	executor_terminal_check('chat_stream')
}

fn test_responses_nonterminal_generator_completes_naturally() { executor_terminal_check('natural') }
