module executor

import config
import os
import runtime_plan

pub fn LogicExecutorRuntimePlan.resolve_from_plan(args []string, legacy_cfg config.VhttpdConfig, plan runtime_plan.RuntimePlan, listener_id string) !LogicExecutorRuntimePlan {
	engine := plan.listener_fallback_engine(listener_id) or {
		return LogicExecutorRuntimePlan.resolve(args, legacy_cfg, config.resolve_worker_sockets_with_defaults(args,
			legacy_cfg.worker.socket, legacy_cfg.worker.pool_size, legacy_cfg.worker.socket_prefix,
			legacy_cfg.worker.sockets.join(',')), legacy_cfg.worker.stream_dispatch,
			legacy_cfg.worker.websocket_dispatch, legacy_cfg.worker.autostart,
			legacy_cfg.worker.cmd, legacy_cfg.worker.env.clone())!
	}
	cfg := vhttpd_config_with_websocket_dispatch_policy_from_plan(legacy_cfg, plan, listener_id,
		engine.id)
	return LogicExecutorRuntimePlan.resolve_engine_from_plan(cfg, engine)!
}

pub fn LogicExecutorRuntimePlan.resolve_engine_from_plan(legacy_cfg config.VhttpdConfig, engine runtime_plan.EnginePlan) !LogicExecutorRuntimePlan {
	mut cfg := legacy_cfg
	cfg.executor.kind = executor_kind_from_engine_plan(engine, legacy_cfg)
	cfg.worker = worker_config_from_engine_plan(engine, legacy_cfg.worker)
	cfg.php = php_config_from_engine_plan(engine, legacy_cfg.php)
	cfg.vjsx = vjsx_config_from_engine_plan(engine, legacy_cfg.vjsx)
	worker_sockets := config.resolve_worker_sockets_with_defaults([]string{}, cfg.worker.socket,
		cfg.worker.pool_size, cfg.worker.socket_prefix, cfg.worker.sockets.join(','))
	return LogicExecutorRuntimePlan.resolve([]string{}, cfg, worker_sockets,
		cfg.worker.stream_dispatch, cfg.worker.websocket_dispatch, cfg.worker.autostart,
		cfg.worker.cmd, cfg.worker.env.clone())!
}

pub fn LogicExecutorRuntimePlan.resolve_additional_engine_from_plan(legacy_cfg config.VhttpdConfig, engine runtime_plan.EnginePlan, executor_name string) !LogicExecutorRuntimePlan {
	mut cfg := legacy_cfg
	if fallback_spec := legacy_cfg.executors[executor_name] {
		cfg.worker = fallback_spec.worker
		cfg.php = fallback_spec.php
		cfg.vjsx = fallback_spec.vjsx
		cfg.executor = fallback_spec.executor
	}
	return LogicExecutorRuntimePlan.resolve_engine_from_plan(cfg, engine)!
}

fn executor_kind_from_engine_plan(engine runtime_plan.EnginePlan, legacy_cfg config.VhttpdConfig) string {
	kind := engine.kind.trim_space()
	if kind in ['php-worker', 'php_worker'] && engine.options.strings['entry'] == ''
		&& engine.options.strings['app'] == '' && legacy_cfg.executor.kind.trim_space() == '' {
		return 'none'
	}
	return match kind {
		'php-worker', 'php_worker' { 'php' }
		else { kind }
	}
}

fn worker_config_from_engine_plan(engine runtime_plan.EnginePlan, fallback config.WorkerConfig) config.WorkerConfig {
	options := engine.options
	return config.WorkerConfig{
		read_timeout_ms:        int_option_or(options, 'read_timeout_ms', fallback.read_timeout_ms)
		autostart:              bool_option_or(options, 'autostart', fallback.autostart)
		cmd:                    string_option_or(options, 'worker_cmd', fallback.cmd)
		stream_dispatch:        bool_option_or(options, 'stream_dispatch', fallback.stream_dispatch)
		queue_capacity:         int_option_or(options, 'queue_capacity', fallback.queue_capacity)
		queue_timeout_ms:       int_option_or(options, 'queue_timeout_ms',
			fallback.queue_timeout_ms)
		restart_backoff_ms:     int_option_or(options, 'restart_backoff_ms',
			fallback.restart_backoff_ms)
		restart_backoff_max_ms: int_option_or(options, 'restart_backoff_max_ms',
			fallback.restart_backoff_max_ms)
		max_requests:           int_option_or(options, 'max_requests', fallback.max_requests)
		socket:                 string_option_or(options, 'socket', string_option_or(options,
			'worker_socket', fallback.socket))
		pool_size:              int_option_or(options, 'pool_size', fallback.pool_size)
		websocket_dispatch:     bool_option_or(options, 'websocket_dispatch',
			fallback.websocket_dispatch)
		socket_prefix:          string_option_or(options, 'socket_prefix', string_option_or(options,
			'worker_socket_prefix', fallback.socket_prefix))
		sockets:                string_list_option_or(options, 'sockets', fallback.sockets)
		env:                    string_map_option_or(options, 'env', fallback.env)
	}
}

fn php_config_from_engine_plan(engine runtime_plan.EnginePlan, fallback config.PhpConfig) config.PhpConfig {
	options := engine.options
	return config.PhpConfig{
		bin:          string_option_or(options, 'binary', fallback.bin)
		worker_entry: file_string_option_or(options, 'entry', fallback.worker_entry)
		app_entry:    file_string_option_or(options, 'app', fallback.app_entry)
		extensions:   file_string_list_option_or(options, 'extensions', fallback.extensions)
		args:         string_list_option_or(options, 'args', fallback.args)
	}
}

fn vjsx_config_from_engine_plan(engine runtime_plan.EnginePlan, fallback config.VjsxConfig) config.VjsxConfig {
	options := engine.options
	return config.VjsxConfig{
		app_entry:         file_string_option_or(options, 'entry', fallback.app_entry)
		module_root:       path_string_option_or(options, 'module_root', fallback.module_root)
		build_root:        path_string_option_or(options, 'build_root', fallback.build_root)
		signature_root:    path_string_option_or(options, 'signature_root', fallback.signature_root)
		signature_include: string_list_option_or(options, 'signature_include',
			fallback.signature_include)
		signature_exclude: string_list_option_or(options, 'signature_exclude',
			fallback.signature_exclude)
		runtime_profile:   string_option_or(options, 'runtime_profile', fallback.runtime_profile)
		thread_count:      int_option_or(options, 'thread_count', fallback.thread_count)
		max_requests:      int_option_or(options, 'max_requests', fallback.max_requests)
		enable_fs:         bool_option_or(options, 'enable_fs', fallback.enable_fs)
		enable_process:    bool_option_or(options, 'enable_process', fallback.enable_process)
		enable_network:    bool_option_or(options, 'enable_network', fallback.enable_network)
	}
}

fn vhttpd_config_with_websocket_dispatch_policy_from_plan(cfg config.VhttpdConfig, plan runtime_plan.RuntimePlan, listener_id string, engine_id string) config.VhttpdConfig {
	mut resolved := cfg
	for pipeline in plan.listener_pipelines(listener_id) {
		if pipeline.egress.domain != .adapter {
			continue
		}
		adapter := plan.adapters[pipeline.egress.id] or { continue }
		engine_ref := adapter.engine or { continue }
		if engine_ref.domain != .engine || engine_ref.id != engine_id {
			continue
		}
		for policy_ref in pipeline.policies {
			if policy_ref.domain != .policy {
				continue
			}
			policy := plan.policies[policy_ref.id] or { continue }
			if policy.category != 'concurrency' {
				continue
			}
			apply_websocket_dispatch_concurrency_policy(policy, mut resolved)
		}
	}
	return resolved
}

fn apply_websocket_dispatch_concurrency_policy(policy runtime_plan.PolicyPlan, mut cfg config.VhttpdConfig) {
	options := policy.options
	if 'affinity_enabled' in options.bools {
		cfg.websocket_affinity.enabled = options.bools['affinity_enabled']
	}
	if source := options.strings['affinity_source'] {
		if source != '' {
			cfg.websocket_affinity.source = source
		}
	}
	if key := options.strings['affinity_key'] {
		if key != '' {
			cfg.websocket_affinity.key = key
		}
	}
	if scope := options.strings['affinity_scope'] {
		if scope != '' {
			cfg.websocket_affinity.scope = scope
		}
	}
	if fallback := options.strings['affinity_fallback'] {
		if fallback != '' {
			cfg.websocket_affinity.fallback = fallback
		}
	}
	if 'actor_enabled' in options.bools {
		cfg.websocket_actor.enabled = options.bools['actor_enabled']
	}
	if fallback := options.strings['actor_fallback'] {
		if fallback != '' {
			cfg.websocket_actor.fallback = fallback
		}
	}
	if queue_timeout_ms := options.ints['queue_timeout_ms'] {
		if queue_timeout_ms != 0 {
			cfg.websocket_actor.queue_timeout_ms = queue_timeout_ms
		}
	}
	if max_queue_per_key := options.ints['max_queue_per_key'] {
		if max_queue_per_key != 0 {
			cfg.websocket_actor.max_queue_per_key = max_queue_per_key
		}
	}
	if events := options.string_lists['events'] {
		if events.len > 0 {
			cfg.websocket_actor.events = events.clone()
		}
	}
	if sources := options.record_lists['sources'] {
		if sources.len > 0 {
			mut actor_sources := []config.WebSocketActorSourceConfig{cap: sources.len}
			for source in sources {
				actor_sources << config.WebSocketActorSourceConfig{
					typ:        source['type']
					key:        source['key']
					class_name: source['class']
				}
			}
			cfg.websocket_actor.sources = actor_sources
		}
	}
}

fn string_option_or(options runtime_plan.PlanOptions, key string, fallback string) string {
	value := options.strings[key]
	return if value != '' && !value.contains(r'${') { value } else { fallback }
}

fn file_string_option_or(options runtime_plan.PlanOptions, key string, fallback string) string {
	value := string_option_or(options, key, fallback)
	if value != '' && !os.exists(value) && fallback != '' && os.exists(fallback) {
		return fallback
	}
	return value
}

fn path_string_option_or(options runtime_plan.PlanOptions, key string, fallback string) string {
	value := string_option_or(options, key, fallback)
	if value != '' && !os.exists(value) && fallback != '' {
		return fallback
	}
	return value
}

fn int_option_or(options runtime_plan.PlanOptions, key string, fallback int) int {
	value := options.ints[key]
	return if value != 0 { value } else { fallback }
}

fn bool_option_or(options runtime_plan.PlanOptions, key string, fallback bool) bool {
	if key in options.bools {
		return options.bools[key]
	}
	return fallback
}

fn string_list_option_or(options runtime_plan.PlanOptions, key string, fallback []string) []string {
	values := options.string_lists[key]
	return if values.len > 0 { values.clone() } else { fallback.clone() }
}

fn file_string_list_option_or(options runtime_plan.PlanOptions, key string, fallback []string) []string {
	values := string_list_option_or(options, key, fallback)
	if values.any(it != '' && !os.exists(it)) && fallback.len > 0 && fallback.all(it == ''
		|| os.exists(it)) {
		return fallback.clone()
	}
	return values
}

fn string_map_option_or(options runtime_plan.PlanOptions, key string, fallback map[string]string) map[string]string {
	if key !in options.string_maps {
		return fallback.clone()
	}
	values := options.string_maps[key].clone()
	return if values.len > 0 { values.clone() } else { fallback.clone() }
}
