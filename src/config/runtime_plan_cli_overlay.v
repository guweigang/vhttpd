module config

import runtime_plan

pub fn runtime_plan_apply_cli_overrides(args []string, cfg VhttpdConfig, plan runtime_plan.RuntimePlan, listener_id string) runtime_plan.RuntimePlan {
	mut engines := plan.engines.clone()
	for engine_id in default_engine_ids_for_listener(plan, listener_id) {
		if engine := engines[engine_id] {
			engines[engine_id] = engine_with_cli_overrides(args, cfg, engine)
		}
	}
	return runtime_plan.RuntimePlan{
		source:        plan.source
		server:        plan.server
		listeners:     plan.listeners.clone()
		control:       plan.control
		observability: plan.observability
		resources:     plan.resources.clone()
		engines:       engines
		adapters:      adapters_with_cli_overrides(args, plan.adapters)
		transforms:    plan.transforms.clone()
		policies:      plan.policies.clone()
		pipelines:     plan.pipelines.clone()
		relays:        relays_with_cli_overrides(args, plan.relays)
		diagnostics:   plan.diagnostics.clone()
	}
}

fn default_engine_ids_for_listener(plan runtime_plan.RuntimePlan, listener_id string) []string {
	target_listener_id := if listener_id.trim_space() == '' { 'default' } else { listener_id }
	mut ids := []string{}
	for pipeline in plan.pipelines {
		if pipeline.ingress.domain != .listener || pipeline.ingress.id != target_listener_id {
			continue
		}
		if '*' !in pipeline.match.paths && !pipeline.id.ends_with('_fallback') {
			continue
		}
		if pipeline.egress.domain != .adapter {
			continue
		}
		if adapter := plan.adapters[pipeline.egress.id] {
			if engine := adapter.engine {
				if engine.domain == .engine && engine.id !in ids {
					ids << engine.id
				}
			}
		}
	}
	return ids
}

fn engine_with_cli_overrides(args []string, cfg VhttpdConfig, engine runtime_plan.EnginePlan) runtime_plan.EnginePlan {
	mut kind := CliArgs.string_or(args, '--executor', engine.kind).trim_space()
	if kind == '' {
		kind = engine.kind
	}
	normalized_kind := match kind {
		'php', 'php_worker', 'php-worker' { 'php-worker' }
		'php_cgi', 'php-cgi' { 'php-cgi' }
		else { kind }
	}
	mut options := clone_plan_options(engine.options)
	options = apply_worker_cli_overrides(args, cfg, options)
	match normalized_kind {
		'php-worker', 'php-cgi' {
			options = apply_php_cli_overrides(args, cfg, options)
		}
		'vjsx' {
			options = apply_vjsx_cli_overrides(args, cfg, options)
		}
		else {}
	}
	return runtime_plan.EnginePlan{
		id:           engine.id
		kind:         normalized_kind
		resources:    engine.resources.clone()
		capabilities: engine.capabilities.clone()
		options:      options
	}
}

fn apply_worker_cli_overrides(args []string, cfg VhttpdConfig, options runtime_plan.PlanOptions) runtime_plan.PlanOptions {
	mut strings := options.strings.clone()
	mut ints := options.ints.clone()
	mut bools := options.bools.clone()
	mut string_lists := clone_string_list_map(options.string_lists)
	if CliArgs.has(args, '--worker-pool-size') {
		ints['pool_size'] = CliArgs.int_or(args, '--worker-pool-size', cfg.worker.pool_size)
	}
	if CliArgs.has(args, '--worker-queue-capacity') {
		ints['queue_capacity'] = CliArgs.int_or(args, '--worker-queue-capacity',
			cfg.worker.queue_capacity)
	}
	if CliArgs.has(args, '--worker-queue-timeout-ms') {
		ints['queue_timeout_ms'] = CliArgs.int_or(args, '--worker-queue-timeout-ms',
			cfg.worker.queue_timeout_ms)
	}
	if CliArgs.has(args, '--worker-read-timeout-ms') {
		ints['read_timeout_ms'] = CliArgs.int_or(args, '--worker-read-timeout-ms',
			cfg.worker.read_timeout_ms)
	}
	if CliArgs.has(args, '--worker-restart-backoff-ms') {
		ints['restart_backoff_ms'] = CliArgs.int_or(args, '--worker-restart-backoff-ms',
			cfg.worker.restart_backoff_ms)
	}
	if CliArgs.has(args, '--worker-restart-backoff-max-ms') {
		ints['restart_backoff_max_ms'] = CliArgs.int_or(args, '--worker-restart-backoff-max-ms',
			cfg.worker.restart_backoff_max_ms)
	}
	if CliArgs.has(args, '--worker-max-requests') {
		ints['max_requests'] = CliArgs.int_or(args, '--worker-max-requests',
			cfg.worker.max_requests)
	}
	if CliArgs.has(args, '--worker-autostart') {
		bools['autostart'] = CliArgs.bool_or(args, '--worker-autostart',
			cfg.worker.autostart)
	}
	if CliArgs.has(args, '--worker-cmd') {
		strings['worker_cmd'] = CliArgs.string_or(args, '--worker-cmd', cfg.worker.cmd)
	}
	if CliArgs.has(args, '--worker-socket') {
		strings['socket'] = CliArgs.string_or(args, '--worker-socket', cfg.worker.socket)
	}
	if CliArgs.has(args, '--worker-socket-prefix') {
		strings['socket_prefix'] = CliArgs.string_or(args, '--worker-socket-prefix',
			cfg.worker.socket_prefix)
	}
	if CliArgs.has(args, '--worker-sockets') {
		string_lists['sockets'] = CliArgs.string_list_or(args, '--worker-sockets',
			cfg.worker.sockets)
	}
	return runtime_plan.PlanOptions{
		strings:      strings
		ints:         ints
		bools:        bools
		string_lists: string_lists
		string_maps:  clone_string_map_map(options.string_maps)
		record_lists: clone_record_list_map(options.record_lists)
	}
}

fn apply_php_cli_overrides(args []string, cfg VhttpdConfig, options runtime_plan.PlanOptions) runtime_plan.PlanOptions {
	mut strings := options.strings.clone()
	mut string_lists := clone_string_list_map(options.string_lists)
	if CliArgs.has(args, '--php-bin') {
		strings['binary'] = CliArgs.string_or(args, '--php-bin', cfg.php.bin)
	}
	if CliArgs.has(args, '--php-worker-entry') {
		strings['entry'] = CliArgs.string_or(args, '--php-worker-entry',
			cfg.php.worker_entry)
	}
	if CliArgs.has(args, '--php-app-entry') {
		strings['app'] = CliArgs.string_or(args, '--php-app-entry', cfg.php.app_entry)
	}
	if CliArgs.has(args, '--php-extension') {
		string_lists['extensions'] = CliArgs.string_list_or(args, '--php-extension', []string{})
	}
	if CliArgs.has(args, '--php-arg') {
		string_lists['args'] = CliArgs.string_list_or(args, '--php-arg', []string{})
	}
	return runtime_plan.PlanOptions{
		strings:      strings
		ints:         options.ints.clone()
		bools:        options.bools.clone()
		string_lists: string_lists
		string_maps:  clone_string_map_map(options.string_maps)
		record_lists: clone_record_list_map(options.record_lists)
	}
}

fn apply_vjsx_cli_overrides(args []string, cfg VhttpdConfig, options runtime_plan.PlanOptions) runtime_plan.PlanOptions {
	mut strings := options.strings.clone()
	mut ints := options.ints.clone()
	mut string_lists := clone_string_list_map(options.string_lists)
	if CliArgs.has(args, '--vjsx-entry') {
		strings['entry'] = CliArgs.string_or(args, '--vjsx-entry', cfg.vjsx.app_entry)
	}
	if CliArgs.has(args, '--vjsx-module-root') {
		strings['module_root'] = CliArgs.string_or(args, '--vjsx-module-root',
			cfg.vjsx.module_root)
	}
	if CliArgs.has(args, '--vjsx-build-root') {
		strings['build_root'] = CliArgs.string_or(args, '--vjsx-build-root',
			cfg.vjsx.build_root)
	}
	if CliArgs.has(args, '--vjsx-signature-root') {
		strings['signature_root'] = CliArgs.string_or(args, '--vjsx-signature-root',
			cfg.vjsx.signature_root)
	}
	if CliArgs.has(args, '--vjsx-signature-include') {
		string_lists['signature_include'] = CliArgs.string_list_or(args,
			'--vjsx-signature-include', []string{})
	}
	if CliArgs.has(args, '--vjsx-signature-exclude') {
		string_lists['signature_exclude'] = CliArgs.string_list_or(args,
			'--vjsx-signature-exclude', []string{})
	}
	if CliArgs.has(args, '--vjsx-runtime-profile') {
		strings['runtime_profile'] = CliArgs.string_or(args, '--vjsx-runtime-profile',
			cfg.vjsx.runtime_profile)
	}
	if CliArgs.has(args, '--vjsx-thread-count') {
		ints['thread_count'] = CliArgs.int_or(args, '--vjsx-thread-count',
			cfg.vjsx.thread_count)
	}
	return runtime_plan.PlanOptions{
		strings:      strings
		ints:         ints
		bools:        options.bools.clone()
		string_lists: string_lists
		string_maps:  clone_string_map_map(options.string_maps)
		record_lists: clone_record_list_map(options.record_lists)
	}
}

fn adapters_with_cli_overrides(args []string, adapters map[string]runtime_plan.AdapterPlan) map[string]runtime_plan.AdapterPlan {
	mut next := map[string]runtime_plan.AdapterPlan{}
	for id, adapter in adapters {
		if adapter.kind == 'feishu-events' {
			next[id] = feishu_adapter_with_cli_overrides(args, adapter)
		} else if adapter.kind == 'codex' || adapter.kind == 'openai' {
			next[id] = codex_adapter_with_cli_overrides(args, adapter)
		} else {
			next[id] = adapter
		}
	}
	return next
}

fn feishu_adapter_with_cli_overrides(args []string, adapter runtime_plan.AdapterPlan) runtime_plan.AdapterPlan {
	options := clone_plan_options(adapter.options)
	mut strings := options.strings.clone()
	mut bools := options.bools.clone()
	mut record_lists := clone_record_list_map(options.record_lists)
	if CliArgs.has(args, '--feishu-enabled') {
		bools['enabled'] = CliArgs.bool_or(args, '--feishu-enabled', false)
	}
	if CliArgs.has(args, '--feishu-open-base-url') {
		strings['open_base_url'] = CliArgs.string_or(args, '--feishu-open-base-url',
			strings['open_base_url'])
	}
	if CliArgs.has(args, '--feishu-app-id') || CliArgs.has(args, '--feishu-app-secret') {
		mut apps := record_lists['apps'].clone()
		apps << {
			'id':         'main'
			'app_id':     CliArgs.string_or(args, '--feishu-app-id', '')
			'app_secret': CliArgs.string_or(args, '--feishu-app-secret', '')
		}
		record_lists['apps'] = apps
	}
	return adapter_with_options(adapter, runtime_plan.PlanOptions{
		strings:      strings
		ints:         options.ints.clone()
		bools:        bools
		string_lists: clone_string_list_map(options.string_lists)
		string_maps:  clone_string_map_map(options.string_maps)
		record_lists: record_lists
	})
}

fn codex_adapter_with_cli_overrides(args []string, adapter runtime_plan.AdapterPlan) runtime_plan.AdapterPlan {
	options := clone_plan_options(adapter.options)
	mut bools := options.bools.clone()
	if CliArgs.has(args, '--ollama-enabled') {
		bools['ollama_enabled'] = CliArgs.bool_or(args, '--ollama-enabled', false)
	}
	return adapter_with_options(adapter, runtime_plan.PlanOptions{
		strings:      options.strings.clone()
		ints:         options.ints.clone()
		bools:        bools
		string_lists: clone_string_list_map(options.string_lists)
		string_maps:  clone_string_map_map(options.string_maps)
		record_lists: clone_record_list_map(options.record_lists)
	})
}

fn adapter_with_options(adapter runtime_plan.AdapterPlan, options runtime_plan.PlanOptions) runtime_plan.AdapterPlan {
	return runtime_plan.AdapterPlan{
		id:      adapter.id
		kind:    adapter.kind
		engine:  adapter.engine
		storage: adapter.storage
		options: options
	}
}

fn relays_with_cli_overrides(args []string, relays map[string]runtime_plan.RelayPlan) map[string]runtime_plan.RelayPlan {
	_ = args
	return relays.clone()
}

fn clone_plan_options(options runtime_plan.PlanOptions) runtime_plan.PlanOptions {
	return runtime_plan.PlanOptions{
		strings:      options.strings.clone()
		ints:         options.ints.clone()
		bools:        options.bools.clone()
		string_lists: clone_string_list_map(options.string_lists)
		string_maps:  clone_string_map_map(options.string_maps)
		record_lists: clone_record_list_map(options.record_lists)
	}
}

fn clone_string_list_map(values map[string][]string) map[string][]string {
	mut cloned := map[string][]string{}
	for key, value in values {
		cloned[key] = value.clone()
	}
	return cloned
}

fn clone_string_map_map(values map[string]map[string]string) map[string]map[string]string {
	mut cloned := map[string]map[string]string{}
	for key, value in values {
		cloned[key] = value.clone()
	}
	return cloned
}

fn clone_record_list_map(values map[string][]map[string]string) map[string][]map[string]string {
	mut cloned := map[string][]map[string]string{}
	for key, records in values {
		mut next_records := []map[string]string{cap: records.len}
		for record in records {
			next_records << record.clone()
		}
		cloned[key] = next_records
	}
	return cloned
}
