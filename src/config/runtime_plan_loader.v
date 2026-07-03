module config

import os
import runtime_plan
import toml

const legacy_config_version = 1
const v2_config_version = 2

pub fn detect_config_version(text string) !int {
	doc := toml.parse_text(text)!
	if version_any := doc.value_opt('version') {
		return version_any.int()
	}
	return legacy_config_version
}

pub fn load_runtime_plan(args []string) !runtime_plan.RuntimePlan {
	config_path := config_path_from_args(args)
	if config_path == '' {
		return compile_v1_runtime_plan(default_vhttpd_config())
	}
	return load_runtime_plan_file(config_path)
}

pub fn load_runtime_plan_or_compile_config(args []string, cfg VhttpdConfig) !runtime_plan.RuntimePlan {
	config_path := config_path_from_args(args)
	if config_path == '' {
		return compile_v1_runtime_plan(cfg)
	}
	return load_runtime_plan_file(config_path)
}

pub fn load_runtime_plan_file(config_path string) !runtime_plan.RuntimePlan {
	text := os.read_file(config_path)!
	version := detect_config_version(text)!
	if version == v2_config_version {
		mut cfg := decode_v2_config_strict(text)!
		resolve_v2_config_variables_and_paths(mut cfg, config_path)!
		return compile_v2_runtime_plan(cfg, os.abs_path(config_path), false)
	}
	if version == legacy_config_version {
		cfg := load_vhttpd_config(['--config', config_path])!
		return compile_v1_runtime_plan(cfg)
	}
	return error('runtime_plan_unsupported_version:${version}')
}

fn decode_v2_config_strict(text string) !V2Config {
	doc := toml.parse_text(text)!
	root := doc.to_any().as_map()
	validate_v2_config_keys(doc, root)!
	mut cfg := doc.decode[V2Config]()!
	apply_v2_provider_specs(text, doc, mut cfg)
	apply_v2_extension_options(root, mut cfg)
	return cfg
}

fn apply_v2_provider_specs(text string, doc toml.Doc, mut cfg V2Config) {
	providers := v2_provider_specs_from_text(text, doc, cfg.providers)
	if providers.len > 0 {
		cfg.providers = providers.clone()
	}
}

fn v2_provider_specs_from_text(text string, doc toml.Doc, existing map[string]V2ProviderSpec) map[string]V2ProviderSpec {
	mut provider_ids := provider_ids_from_v2_text(text)
	if providers_any := doc.value_opt('providers') {
		providers_root := providers_any.as_map()
		for id in providers_root.keys() {
			provider_ids[id] = true
		}
	}
	if provider_ids.len > 0 {
		mut providers := map[string]V2ProviderSpec{}
		for id, provider in existing {
			providers[id] = provider
		}
		mut ids := provider_ids.keys()
		ids.sort()
		for id in ids {
			mut provider := providers[id] or { V2ProviderSpec{} }
			if runtime_any := doc.value_opt('providers.${id}.runtime') {
				runtime_root := runtime_any.as_map()
				mut runtime := provider.runtime
				if driver_any := runtime_root['driver'] {
					runtime.driver = driver_any.string()
				}
				if plugin_any := runtime_root['plugin'] {
					runtime.plugin = plugin_any.string()
				}
				if engine_any := runtime_root['engine'] {
					runtime.engine = engine_any.string()
				}
				provider.runtime = runtime
			}
			if capabilities_any := doc.value_opt('providers.${id}.capabilities') {
				provider.capabilities = decode_v2_string_options(capabilities_any)
			}
			if runtime_driver_any := doc.value_opt('providers.${id}.runtime_driver') {
				provider.runtime_driver = runtime_driver_any.string()
			}
			if runtime_plugin_any := doc.value_opt('providers.${id}.runtime_plugin') {
				provider.runtime_plugin = runtime_plugin_any.string()
			}
			if options_any := doc.value_opt('providers.${id}.options') {
				provider.options = decode_v2_string_options(options_any)
			}
			providers[id] = provider
		}
		return providers
	}
	return existing.clone()
}

fn provider_ids_from_v2_text(text string) map[string]bool {
	mut ids := map[string]bool{}
	for raw_line in text.split_into_lines() {
		line := raw_line.trim_space()
		if !line.starts_with('[providers.') {
			continue
		}
		table := line.trim_left('[').trim_right(']')
		parts := table.split('.')
		if parts.len >= 2 && parts[0] == 'providers' && parts[1].trim_space() != '' {
			ids[parts[1].trim_space()] = true
		}
	}
	return ids
}

fn apply_v2_extension_options(root map[string]toml.Any, mut cfg V2Config) {
	if adapters_any := root['adapters'] {
		adapters_root := adapters_any.as_map()
		for id, spec_any in adapters_root {
			spec_root := spec_any.as_map()
			mut adapter := cfg.adapters[id] or { continue }
			if int_options_any := spec_root['int_options'] {
				adapter.int_options = decode_v2_int_options(int_options_any)
			}
			if bool_options_any := spec_root['bool_options'] {
				adapter.bool_options = decode_v2_bool_options(bool_options_any)
			}
			if list_options_any := spec_root['list_options'] {
				adapter.list_options = decode_v2_list_options(list_options_any)
			}
			if map_options_any := spec_root['map_options'] {
				adapter.map_options = decode_v2_map_options(map_options_any)
			}
			if record_options_any := spec_root['record_options'] {
				adapter.record_options = decode_v2_record_options(record_options_any)
			}
			cfg.adapters[id] = adapter
		}
	}
	if transforms_any := root['transforms'] {
		transforms_root := transforms_any.as_map()
		for id, spec_any in transforms_root {
			spec_root := spec_any.as_map()
			mut transform := cfg.transforms[id] or { continue }
			if int_options_any := spec_root['int_options'] {
				transform.int_options = decode_v2_int_options(int_options_any)
			}
			if bool_options_any := spec_root['bool_options'] {
				transform.bool_options = decode_v2_bool_options(bool_options_any)
			}
			if list_options_any := spec_root['list_options'] {
				transform.list_options = decode_v2_list_options(list_options_any)
			}
			if map_options_any := spec_root['map_options'] {
				transform.map_options = decode_v2_map_options(map_options_any)
			}
			if record_options_any := spec_root['record_options'] {
				transform.record_options = decode_v2_record_options(record_options_any)
			}
			cfg.transforms[id] = transform
		}
	}
}

fn decode_v2_string_options(options_any toml.Any) map[string]string {
	mut options := map[string]string{}
	for key, value in options_any.as_map() {
		options[key] = value.string()
	}
	return options
}

fn decode_v2_int_options(options_any toml.Any) map[string]int {
	mut options := map[string]int{}
	for key, value in options_any.as_map() {
		options[key] = value.int()
	}
	return options
}

fn decode_v2_bool_options(options_any toml.Any) map[string]bool {
	mut options := map[string]bool{}
	for key, value in options_any.as_map() {
		options[key] = value.bool()
	}
	return options
}

fn decode_v2_list_options(options_any toml.Any) map[string][]string {
	mut options := map[string][]string{}
	for key, values_any in options_any.as_map() {
		options[key] = values_any.array().map(it.string())
	}
	return options
}

fn decode_v2_map_options(options_any toml.Any) map[string]map[string]string {
	mut options := map[string]map[string]string{}
	for key, values_any in options_any.as_map() {
		mut values := map[string]string{}
		for item_key, item_value in values_any.as_map() {
			values[item_key] = item_value.string()
		}
		options[key] = values.clone()
	}
	return options
}

fn decode_v2_record_options(record_options_any toml.Any) map[string][]map[string]string {
	mut record_options := map[string][]map[string]string{}
	for name, records_any in record_options_any.as_map() {
		mut records := []map[string]string{}
		for record_any in records_any.array() {
			mut record := map[string]string{}
			for key, value in record_any.as_map() {
				record[key] = value.string()
			}
			records << record
		}
		record_options[name] = records
	}
	return record_options
}

fn resolve_v2_config_variables_and_paths(mut cfg V2Config, config_path string) ! {
	env_map := os.environ()
	base_dir := resolve_config_base_dir(config_path)
	vars := {
		'config.dir': base_dir
		'paths.root': base_dir
	}
	cfg.server.pid_file = resolve_v2_path_string(cfg.server.pid_file, base_dir, 'server', vars,
		env_map)!
	cfg.observability.event_log = resolve_v2_path_string(cfg.observability.event_log, base_dir,
		'observability', vars, env_map)!
	for id, mut listener in cfg.listeners {
		listener.tls.cert = resolve_v2_path_string(listener.tls.cert, base_dir,
			'listeners.${id}.tls', vars, env_map)!
		listener.tls.cert_key = resolve_v2_path_string(listener.tls.cert_key, base_dir,
			'listeners.${id}.tls', vars, env_map)!
		for i, mut certificate in listener.tls.certificates {
			certificate.cert = resolve_v2_path_string(certificate.cert, base_dir,
				'listeners.${id}.tls.certificates', vars, env_map)!
			certificate.cert_key = resolve_v2_path_string(certificate.cert_key, base_dir,
				'listeners.${id}.tls.certificates', vars, env_map)!
			listener.tls.certificates[i] = certificate
		}
		cfg.listeners[id] = listener
	}
	for id, mut resource in cfg.resources.cache {
		resource.socket = resolve_v2_path_string(resource.socket, base_dir,
			'resources.cache.${id}', vars, env_map)!
		cfg.resources.cache[id] = resource
	}
	for id, mut resource in cfg.resources.storage {
		resource.root = resolve_v2_path_string(resource.root, base_dir, 'resources.storage.${id}',
			vars, env_map)!
		cfg.resources.storage[id] = resource
	}
	for id, mut engine in cfg.engines {
		engine.entry = resolve_v2_path_string(engine.entry, base_dir, 'engines.${id}', vars,
			env_map)!
		engine.app = resolve_v2_path_string(engine.app, base_dir, 'engines.${id}', vars, env_map)!
		engine.module_root = resolve_v2_path_string(engine.module_root, base_dir, 'engines.${id}',
			vars, env_map)!
		engine.build_root = resolve_v2_path_string(engine.build_root, base_dir, 'engines.${id}',
			vars, env_map)!
		engine.socket = resolve_v2_path_string(engine.socket, base_dir, 'engines.${id}', vars,
			env_map)!
		engine.socket_prefix = resolve_v2_path_string(engine.socket_prefix, base_dir,
			'engines.${id}', vars, env_map)!
		engine.signature_root = resolve_v2_path_string(engine.signature_root, base_dir,
			'engines.${id}', vars, env_map)!
		for i, raw in engine.sockets {
			engine.sockets[i] = resolve_v2_path_string(raw, base_dir, 'engines.${id}', vars,
				env_map)!
		}
		for i, raw in engine.extensions {
			engine.extensions[i] = resolve_v2_path_string(raw, base_dir, 'engines.${id}', vars,
				env_map)!
		}
		for key, raw in engine.env {
			engine.env[key] = resolve_v2_value_string(raw, 'engines.${id}.env', vars, env_map)!
		}
		for key, raw in engine.options {
			engine.options[key] = resolve_v2_value_string(raw, 'engines.${id}.options', vars,
				env_map)!
		}
		cfg.engines[id] = engine
	}
	for id, mut adapter in cfg.adapters {
		adapter.document_root = resolve_v2_path_string(adapter.document_root, base_dir,
			'adapters.${id}', vars, env_map)!
		adapter.root = resolve_v2_path_string(adapter.root, base_dir, 'adapters.${id}', vars,
			env_map)!
		for key, raw in adapter.options {
			adapter.options[key] = resolve_v2_value_string(raw, 'adapters.${id}.options', vars,
				env_map)!
		}
		cfg.adapters[id] = adapter
	}
}

fn resolve_v2_value_string(raw string, scope string, vars map[string]string, env_map map[string]string) !string {
	value, _ := expand_config_string(raw, scope, vars, env_map, false)!
	return value
}

fn resolve_v2_path_string(raw string, root string, scope string, vars map[string]string, env_map map[string]string) !string {
	value := resolve_v2_value_string(raw, scope, vars, env_map)!
	return resolve_config_path(root, value)
}

fn validate_v2_config_keys(doc toml.Doc, root map[string]toml.Any) ! {
	validate_keys(root, '', ['version', 'server', 'listeners', 'control', 'observability',
		'resources', 'engines', 'adapters', 'transforms', 'policies', 'providers', 'pipelines',
		'relays'])!
	validate_optional_table(root, 'server', ['timezone', 'pid_file', 'shutdown_timeout_ms'])!
	validate_listener_specs(root)!
	validate_optional_table(root, 'control', ['listener', 'token', 'internal_socket'])!
	validate_observability_specs(root)!
	validate_resource_specs(root)!
	validate_named_specs(root, 'engines', ['kind', 'entry', 'app', 'binary', 'module_root',
		'build_root', 'runtime_profile', 'pool_size', 'thread_count', 'queue_capacity',
		'queue_timeout_ms', 'read_timeout_ms', 'restart_backoff_ms', 'restart_backoff_max_ms',
		'max_requests', 'autostart', 'stream_dispatch', 'websocket_dispatch', 'enable_fs',
		'enable_process', 'enable_network', 'socket', 'socket_prefix', 'sockets', 'signature_root',
		'signature_include', 'signature_exclude', 'resources', 'capabilities', 'env', 'args',
		'extensions', 'options'])!
	validate_named_specs(root, 'adapters', ['kind', 'engine', 'storage', 'document_root', 'index',
		'root', 'base_url', 'timeout_ms', 'max_body_bytes', 'completed_pipeline', 'topic',
		'provider', 'action', 'capability', 'runtime_driver', 'runtime_plugin', 'runtime_engine',
		'options', 'int_options', 'bool_options', 'list_options', 'map_options', 'record_options'])!
	validate_named_specs(root, 'transforms', ['kind', 'engine', 'handler', 'target', 'strip_prefix',
		'options', 'int_options', 'bool_options', 'list_options', 'map_options', 'record_options'])!
	validate_policy_specs(root)!
	validate_provider_specs(doc)!
	validate_pipeline_specs(root)!
	validate_named_specs(root, 'relays', ['mode', 'carrier', 'listener', 'auth', 'url', 'path',
		'node_id', 'token', 'autostart', 'max_channels', 'channel_buffer', 'reconnect_delay_ms',
		'options'])!
}

fn validate_provider_specs(doc toml.Doc) ! {
	value := doc.value_opt('providers') or { return }
	if value is map[string]toml.Any {
		for id, spec_any in value {
			if spec_any is map[string]toml.Any {
				validate_keys(spec_any, 'providers.${id}', ['runtime', 'capabilities', 'runtime_driver',
					'runtime_plugin', 'options'])!
				runtime_any := spec_any['runtime'] or { continue }
				if runtime_any is map[string]toml.Any {
					validate_keys(runtime_any, 'providers.${id}.runtime', ['driver', 'plugin', 'engine'])!
				}
			}
		}
	}
}

fn validate_keys(entry map[string]toml.Any, path string, allowed []string) ! {
	for key, _ in entry {
		if key !in allowed {
			return error('v2_config_unknown_field:${format_config_path(path, key)}')
		}
	}
}

fn format_config_path(path string, key string) string {
	if path == '' {
		return key
	}
	return '${path}.${key}'
}

fn validate_optional_table(root map[string]toml.Any, key string, allowed []string) ! {
	value := root[key] or { return }
	if value is map[string]toml.Any {
		validate_keys(value, key, allowed)!
	}
}

fn validate_named_specs(root map[string]toml.Any, key string, allowed []string) ! {
	value := root[key] or { return }
	if value is map[string]toml.Any {
		for id, spec_any in value {
			if spec_any is map[string]toml.Any {
				validate_keys(spec_any, '${key}.${id}', allowed)!
			}
		}
	}
}

fn validate_listener_specs(root map[string]toml.Any) ! {
	value := root['listeners'] or { return }
	if value is map[string]toml.Any {
		for id, spec_any in value {
			if spec_any is map[string]toml.Any {
				validate_keys(spec_any, 'listeners.${id}', ['protocol', 'transport', 'host', 'port',
					'tls'])!
				tls_any := spec_any['tls'] or { continue }
				if tls_any is map[string]toml.Any {
					validate_keys(tls_any, 'listeners.${id}.tls', ['enabled', 'cert', 'cert_key',
						'certificates'])!
					validate_array_specs(tls_any, 'certificates',
						'listeners.${id}.tls.certificates', ['hosts', 'cert', 'cert_key'])!
				}
			}
		}
	}
}

fn validate_observability_specs(root map[string]toml.Any) ! {
	value := root['observability'] or { return }
	if value is map[string]toml.Any {
		validate_keys(value, 'observability', ['event_log', 'log_level', 'tracing'])!
		tracing_any := value['tracing'] or { return }
		if tracing_any is map[string]toml.Any {
			validate_keys(tracing_any, 'observability.tracing', ['enabled', 'exporter', 'endpoint',
				'sample_rate'])!
		}
	}
}

fn validate_resource_specs(root map[string]toml.Any) ! {
	value := root['resources'] or { return }
	if value is map[string]toml.Any {
		validate_keys(value, 'resources', ['db', 'cache', 'storage', 'secret'])!
		validate_named_specs(value, 'db', ['kind', 'host', 'port', 'database', 'username', 'password',
			'pool_size', 'idle_ping_ms', 'init_sql', 'options'])!
		validate_named_specs(value, 'cache', ['kind', 'socket', 'url', 'namespace', 'options'])!
		validate_named_specs(value, 'storage', ['kind', 'root', 'bucket', 'options'])!
		validate_named_specs(value, 'secret', ['kind', 'source', 'options'])!
	}
}

fn validate_policy_specs(root map[string]toml.Any) ! {
	value := root['policies'] or { return }
	if value is map[string]toml.Any {
		validate_keys(value, 'policies', ['cache', 'limits', 'security', 'response', 'retry',
			'concurrency'])!
		validate_named_specs(value, 'cache', ['cache_control', 'ttl_ms', 'bypass_cookie_patterns',
			'ignore_cookie_patterns'])!
		validate_named_specs(value, 'limits', ['max_body_bytes', 'timeout_ms', 'queue_capacity'])!
		validate_named_specs(value, 'security', ['required_headers', 'denied_query_patterns',
			'allowed_origins'])!
		validate_named_specs(value, 'response', ['headers'])!
		validate_named_specs(value, 'retry', ['max_attempts', 'backoff_ms', 'backoff_max_ms'])!
		validate_named_specs(value, 'concurrency', ['max_in_flight', 'queue_capacity',
			'queue_timeout_ms'])!
	}
}

fn validate_pipeline_specs(root map[string]toml.Any) ! {
	value := root['pipelines'] or { return }
	if value is []toml.Any {
		for index, spec_any in value {
			if spec_any is map[string]toml.Any {
				path := 'pipelines[${index}]'
				validate_keys(spec_any, path, ['id', 'group', 'ingress', 'match', 'transforms',
					'policies', 'egress'])!
				match_any := spec_any['match'] or { continue }
				if match_any is map[string]toml.Any {
					validate_keys(match_any, '${path}.match', ['methods', 'hosts', 'paths',
						'path_regexp', 'query', 'headers', 'metadata'])!
				}
			}
		}
	}
}

fn validate_array_specs(root map[string]toml.Any, key string, path string, allowed []string) ! {
	value := root[key] or { return }
	if value is []toml.Any {
		for index, spec_any in value {
			if spec_any is map[string]toml.Any {
				validate_keys(spec_any, '${path}[${index}]', allowed)!
			}
		}
	}
}
