module main

import os
import x.json2

fn test_openai_relative_path_matches_configured_base_path() {
	assert openai_relative_path('/v1/models', '/v1') or { '' } == '/models'
	assert openai_relative_path('api/openai/chat/completions?trace=1', '/api/openai') or { '' } == '/chat/completions'
	if _ := openai_relative_path('/api/other/models', '/api/openai') {
		assert false
	} else {
		assert true
	}
}

fn test_openai_route_resolution_maps_public_model_to_upstream_model() {
	mut app := App{
		openai_enabled:         true
		openai_base_path:       '/v1'
		openai_default_backend: 'default'
		openai_backends:        {
			'default': OpenAIBackendConfig{
				base_url: 'https://upstream.test/v1'
			}
		}
		openai_routes:          {
			'gpt-4o-mini': OpenAIRouteConfig{
				models:         ['gpt-4o-mini', 'mini']
				backend:        'default'
				upstream_model: 'upstream-mini'
			}
		}
	}
	route := app.openai_resolve_route('mini') or { panic(err) }
	assert route.backend_name == 'default'
	assert route.upstream_model == 'upstream-mini'
	assert app.openai_models() == ['gpt-4o-mini', 'mini']
}

fn test_openai_responses_builtin_plan_uses_responses_path() {
	mut app := App{
		openai_enabled:         true
		openai_base_path:       '/v1'
		openai_default_backend: 'default'
		openai_backends:        {
			'default': OpenAIBackendConfig{
				base_url: 'https://upstream.test/v1'
			}
		}
		openai_routes:          {
			'public': OpenAIRouteConfig{
				models:         ['public-model']
				backend:        'default'
				upstream_model: 'upstream-model'
			}
		}
	}
	plan := app.openai_resolve_responses_plan('public-model', '{"model":"public-model","input":"hi"}',
		'POST', '/v1/responses', 'req_resp', 'trace_resp') or { panic(err) }
	assert plan.path == '/responses'
	assert plan.output_protocol == 'openai.response'
	assert plan.body.contains('"model":"upstream-model"')
}

fn test_openai_replace_model_in_body_keeps_other_fields() {
	body := openai_replace_model_in_body('{"model":"public","messages":[{"role":"user","content":"hi"}],"stream":true}',
		'upstream')
	root := json2.decode[json2.Any](body) or { panic(err) }.as_map()
	assert (root['model'] or { json2.Any('') }).str() == 'upstream'
	assert (root['stream'] or { json2.Any(false) }).bool()
	assert (root['messages'] or { json2.Any([]json2.Any{}) }).as_array().len == 1
}

fn test_openai_config_parses_backends_and_routes() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_config_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	config_file := os.join_path(temp_dir, 'vhttpd.toml')
	os.write_file(config_file, '
[openai]
enabled = true
base_path = "/openai/v1"
default_backend = "default"
plugin = "planner"

[plugins.planner]
kind = "vjsx"
entry = "plugins/openai-planner.mts"
runtime_profile = "node"

[openai.backends.default]
kind = "openai_http"
base_url = "https://api.openai.test/v1"
api_key_env = "TEST_OPENAI_KEY"

[openai.backends.exec]
kind = "executor"
executor = "custom_executor"

[openai.routes.gpt_demo]
models = ["gpt-demo", "demo"]
backend = "default"
upstream_model = "gpt-4o-mini"
') or {
		panic(err)
	}
	defer {
		os.rm(config_file) or {}
		os.rmdir_all(temp_dir) or {}
	}
	cfg := load_vhttpd_config(['--config', config_file]) or { panic(err) }
	assert cfg.openai.enabled
	assert cfg.openai.base_path == '/openai/v1'
	assert cfg.openai.plugin == 'planner'
	assert cfg.openai.endpoints.responses
	assert cfg.plugins['planner'].runtime_profile == 'node'
	assert cfg.openai.backends['default'].base_url == 'https://api.openai.test/v1'
	assert cfg.openai.backends['exec'].kind == 'executor'
	assert cfg.openai.backends['exec'].executor == 'custom_executor'
	assert cfg.openai.routes['gpt_demo'].models == ['gpt-demo', 'demo']
	assert cfg.openai.routes['gpt_demo'].upstream_model == 'gpt-4o-mini'
}

fn test_openai_vjsx_plugin_can_return_upstream_plan() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_plugin_plan_test')
	plugin_dir := os.join_path(temp_dir, 'plugins')
	os.mkdir_all(plugin_dir) or { panic(err) }
	plugin_file := os.join_path(plugin_dir, 'openai-planner.mts')
	os.write_file(plugin_file, "
export function openai(req) {
  if (req.op !== 'chat.route') {
    return { not_handled: true };
  }
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
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	plugins := {
		'planner': PluginConfig{
			kind:            'vjsx'
			app_entry:       plugin_file
			runtime_profile: 'node'
			thread_count:    1
		}
	}
	mut app := App{
		started_at_unix:        123
		openai_enabled:         true
		openai_base_path:       '/v1'
		openai_plugin:          'planner'
		openai_default_backend: 'mock'
		openai_backends:        {
			'mock': OpenAIBackendConfig{
				base_url: 'https://mock.openai.test/v1'
			}
		}
		plugin_configs:         plugins
		plugin_vjsx:            build_vjsx_plugin_runtimes(plugins)
	}
	defer {
		app.close_all_plugins()
	}
	plan := app.openai_resolve_plan('public-model', '{"model":"public-model","messages":[]}',
		'POST', '/v1/chat/completions', 'req_plugin', 'trace_plugin') or { panic(err) }
	assert plan.backend_name == 'mock'
	assert plan.path == '/chat/completions'
	assert plan.headers['x-plugin-plan'] == 'yes'
	root := json2.decode[json2.Any](plan.body) or { panic(err) }.as_map()
	assert (root['model'] or { json2.Any('') }).str() == 'plugin-upstream-model'
}

fn test_openai_vjsx_plugin_models_uses_same_openai_entry() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_plugin_models_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	plugin_file := os.join_path(temp_dir, 'openai-planner.mts')
	os.write_file(plugin_file, "
export function openai(req) {
  if (req.op === 'models') {
    return { models: ['plugin-b', 'plugin-a', 'plugin-a'] };
  }
  return { not_handled: true };
}
") or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	plugins := {
		'planner': PluginConfig{
			kind:            'vjsx'
			app_entry:       plugin_file
			runtime_profile: 'node'
			thread_count:    1
		}
	}
	mut app := App{
		openai_enabled:   true
		openai_base_path: '/v1'
		openai_plugin:    'planner'
		plugin_configs:   plugins
		plugin_vjsx:      build_vjsx_plugin_runtimes(plugins)
	}
	defer {
		app.close_all_plugins()
	}
	result := app.openai_plugin_models('GET', '/v1/models', 'req_models', 'trace_models') or {
		panic(err)
	}
	assert result.handled
	assert result.models == ['plugin-a', 'plugin-b']
}

fn test_openai_vjsx_plugin_not_handled_falls_back_to_builtin_route() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_openai_plugin_not_handled_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	plugin_file := os.join_path(temp_dir, 'openai-planner.mts')
	os.write_file(plugin_file, '
export function openai(_req) {
  return { not_handled: true };
}
') or {
		panic(err)
	}
	defer {
		os.rmdir_all(temp_dir) or {}
	}
	plugins := {
		'planner': PluginConfig{
			kind:            'vjsx'
			app_entry:       plugin_file
			runtime_profile: 'node'
			thread_count:    1
		}
	}
	mut app := App{
		openai_enabled:         true
		openai_base_path:       '/v1'
		openai_plugin:          'planner'
		openai_default_backend: 'mock'
		openai_backends:        {
			'mock': OpenAIBackendConfig{
				base_url: 'https://mock.openai.test/v1'
			}
		}
		openai_routes:          {
			'public': OpenAIRouteConfig{
				models:         ['public-model']
				backend:        'mock'
				upstream_model: 'builtin-upstream-model'
			}
		}
		plugin_configs:         plugins
		plugin_vjsx:            build_vjsx_plugin_runtimes(plugins)
	}
	defer {
		app.close_all_plugins()
	}
	plan := app.openai_resolve_plan('public-model', '{"model":"public-model","messages":[]}',
		'POST', '/v1/chat/completions', 'req_fallback', 'trace_fallback') or { panic(err) }
	assert plan.backend_name == 'mock'
	root := json2.decode[json2.Any](plan.body) or { panic(err) }.as_map()
	assert (root['model'] or { json2.Any('') }).str() == 'builtin-upstream-model'
}

fn test_openai_plugin_plan_validation_rejects_missing_backend() {
	raw := '{"method":"POST","path":"/chat/completions","body":"{}"}'
	plan := openai_upstream_plan_from_plugin_json(raw) or { panic(err) }
	mut app := App{}
	_ := app
	if plan.backend.trim_space() == '' {
		err := openai_plan_error('openai_plugin_plan_missing_backend', 'plugin plan must include backend')
		assert openai_plan_error_code(err.msg()) == 'openai_plugin_plan_missing_backend'
		assert openai_plan_error_message(err.msg()) == 'plugin plan must include backend'
		return
	}
	assert false
}

fn test_openai_plugin_plan_validation_rejects_invalid_method_and_path() {
	openai_validate_plan_method('TRACE') or {
		assert openai_plan_error_code(err.msg()) == 'openai_plugin_plan_invalid_method'
		assert openai_plan_error_message(err.msg()).contains('TRACE')
	}
	openai_validate_plan_path('chat/completions') or {
		assert openai_plan_error_code(err.msg()) == 'openai_plugin_plan_invalid_path'
		assert openai_plan_error_message(err.msg()).contains('start with /')
	}
	assert openai_validate_stream_mode('mapped') or { panic(err) } == 'mapped'
	openai_validate_response_codec('xml', 'mapped') or {
		assert openai_plan_error_code(err.msg()) == 'openai_plugin_plan_unsupported_response_codec'
		assert openai_plan_error_message(err.msg()).contains('xml')
	}
	openai_validate_output_protocol('custom.protocol', 'mapped') or {
		assert openai_plan_error_code(err.msg()) == 'openai_plugin_plan_unsupported_output_protocol'
		assert openai_plan_error_message(err.msg()).contains('custom.protocol')
	}
	assert openai_validate_mapper('plugin') or { panic(err) } == 'plugin'
	openai_validate_mapper('remote') or {
		assert openai_plan_error_code(err.msg()) == 'openai_plugin_plan_unsupported_mapper'
		assert openai_plan_error_message(err.msg()).contains('remote')
	}
}

fn test_openai_plugin_plan_sanitizes_hop_by_hop_headers() {
	headers := openai_sanitize_plan_headers({
		'x-ok':              'yes'
		'connection':        'close'
		'transfer-encoding': 'chunked'
		'host':              'bad'
		'x-bad':             'line\r\nbreak'
	})
	assert headers['x-ok'] == 'yes'
	assert 'connection' !in headers
	assert 'transfer-encoding' !in headers
	assert 'host' !in headers
	assert 'x-bad' !in headers
}

fn test_openai_mapped_once_ndjson_aggregates_chat_completion() {
	body := '{"message":{"content":"你"},"done":false}\n' +
		'{"message":{"content":"好"},"done":false}\n' + '{"done":true}\n'
	mapped := openai_map_once_response(OpenAIResolvedPlan{
		model:           'public-model'
		stream_mode:     'mapped'
		response_codec:  'ndjson'
		output_protocol: 'openai.chat.completion'
	}, body, 'req_once', 123) or { panic(err) }
	root := json2.decode[json2.Any](mapped) or { panic(err) }.as_map()
	assert (root['object'] or { json2.Any('') }).str() == 'chat.completion'
	choices := (root['choices'] or { json2.Any([]json2.Any{}) }).as_array()
	assert choices.len == 1
	message := (choices[0].as_map()['message'] or { json2.Any(map[string]json2.Any{}) }).as_map()
	assert (message['content'] or { json2.Any('') }).str() == '你好'
}

fn test_openai_mapped_once_ndjson_aggregates_tool_calls() {
	body :=
		'{"message":{"tool_calls":[{"index":0,"id":"call_search","type":"function","function":{"name":"search","arguments":"{\\"q\\":\\"vh"}}]},"done":false}\n' +
		'{"message":{"tool_calls":[{"index":0,"function":{"arguments":"ttpd\\"}"}}]},"done":false}\n' +
		'{"done":true}\n'
	mapped := openai_map_once_response(OpenAIResolvedPlan{
		model:           'public-model'
		stream_mode:     'mapped'
		response_codec:  'ndjson'
		output_protocol: 'openai.chat.completion'
	}, body, 'req_tools', 123) or { panic(err) }
	root := json2.decode[json2.Any](mapped) or { panic(err) }.as_map()
	choices := (root['choices'] or { json2.Any([]json2.Any{}) }).as_array()
	message := (choices[0].as_map()['message'] or { json2.Any(map[string]json2.Any{}) }).as_map()
	tool_calls := (message['tool_calls'] or { json2.Any([]json2.Any{}) }).as_array()
	assert tool_calls.len == 1
	call := tool_calls[0].as_map()
	assert (call['id'] or { json2.Any('') }).str() == 'call_search'
	fn_obj := (call['function'] or { json2.Any(map[string]json2.Any{}) }).as_map()
	assert (fn_obj['name'] or { json2.Any('') }).str() == 'search'
	assert (fn_obj['arguments'] or { json2.Any('') }).str() == '{"q":"vhttpd"}'
	assert (choices[0].as_map()['finish_reason'] or { json2.Any('') }).str() == 'tool_calls'
}

fn test_openai_mapped_once_ndjson_normalizes_usage() {
	body := '{"message":{"content":"hi"},"done":false}\n' +
		'{"done":true,"prompt_eval_count":7,"eval_count":11}\n'
	mapped := openai_map_once_response(OpenAIResolvedPlan{
		model:           'public-model'
		stream_mode:     'mapped'
		response_codec:  'ndjson'
		output_protocol: 'openai.chat.completion'
	}, body, 'req_usage', 123) or { panic(err) }
	root := json2.decode[json2.Any](mapped) or { panic(err) }.as_map()
	usage := (root['usage'] or { json2.Any(map[string]json2.Any{}) }).as_map()
	assert (usage['prompt_tokens'] or { json2.Any(0) }).int() == 7
	assert (usage['completion_tokens'] or { json2.Any(0) }).int() == 11
	assert (usage['total_tokens'] or { json2.Any(0) }).int() == 18
}
