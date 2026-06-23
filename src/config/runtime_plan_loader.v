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
		cfg := decode_v2_config_strict(text)!
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
	validate_v2_config_keys(doc.to_any().as_map())!
	return doc.decode[V2Config]()!
}

fn validate_v2_config_keys(root map[string]toml.Any) ! {
	validate_keys(root, '', ['version', 'server', 'listeners', 'control', 'observability',
		'resources', 'engines', 'adapters', 'transforms', 'policies', 'pipelines', 'relays'])!
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
		'root', 'base_url', 'timeout_ms', 'max_body_bytes', 'completed_pipeline', 'topic', 'options',
		'int_options', 'bool_options', 'list_options', 'map_options', 'record_options'])!
	validate_named_specs(root, 'transforms', ['kind', 'engine', 'handler', 'target', 'strip_prefix',
		'options'])!
	validate_policy_specs(root)!
	validate_pipeline_specs(root)!
	validate_named_specs(root, 'relays', ['mode', 'carrier', 'listener', 'auth', 'url', 'path',
		'node_id', 'token', 'max_channels', 'channel_buffer', 'reconnect_delay_ms', 'options'])!
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
