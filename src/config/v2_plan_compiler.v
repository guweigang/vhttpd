module config

import runtime_plan

pub fn compile_v2_runtime_plan(cfg V2Config, source_path string, compatibility bool) !runtime_plan.RuntimePlan {
	return compile_v2_runtime_plan_with_diagnostics(cfg, source_path, compatibility, [])
}

fn compile_v2_runtime_plan_with_diagnostics(cfg V2Config, source_path string, compatibility bool, diagnostics []runtime_plan.PlanDiagnostic) !runtime_plan.RuntimePlan {
	if cfg.version != 2 {
		return error('runtime_plan_unsupported_version:${cfg.version}')
	}
	mut listeners := map[string]runtime_plan.ListenerPlan{}
	for id, spec in cfg.listeners {
		listeners[id] = runtime_plan.ListenerPlan{
			id:        id
			protocol:  spec.protocol
			transport: spec.transport
			host:      spec.host
			port:      spec.port
			tls:       compile_v2_tls_plan(spec.tls)
		}
	}
	mut resources := map[string]runtime_plan.ResourcePlan{}
	compile_v2_db_resources(cfg.resources.db, mut resources)
	compile_v2_cache_resources(cfg.resources.cache, mut resources)
	compile_v2_storage_resources(cfg.resources.storage, mut resources)
	compile_v2_secret_resources(cfg.resources.secret, mut resources)

	mut engines := map[string]runtime_plan.EnginePlan{}
	for id, spec in cfg.engines {
		engines[id] = runtime_plan.EnginePlan{
			id:           id
			kind:         spec.kind
			resources:    parse_ref_list(spec.resources, .resource)!
			capabilities: spec.capabilities.clone()
			options:      compile_v2_engine_options(spec)
		}
	}
	mut adapters := map[string]runtime_plan.AdapterPlan{}
	for id, spec in cfg.adapters {
		engine_ref := parse_optional_ref(spec.engine, .engine)!
		storage_ref := parse_optional_ref(spec.storage, .resource)!
		adapters[id] = runtime_plan.AdapterPlan{
			id:      id
			kind:    spec.kind
			engine:  engine_ref.option()
			storage: storage_ref.option()
			options: compile_v2_adapter_options(spec)
		}
	}
	mut transforms := map[string]runtime_plan.TransformPlan{}
	for id, spec in cfg.transforms {
		engine_ref := parse_optional_ref(spec.engine, .engine)!
		transforms[id] = runtime_plan.TransformPlan{
			id:      id
			kind:    spec.kind
			engine:  engine_ref.option()
			handler: spec.handler
			options: runtime_plan.PlanOptions{
				strings: merge_string_options({
					'target':       spec.target
					'strip_prefix': spec.strip_prefix
				}, spec.options)
			}
		}
	}
	policies := compile_v2_policies(cfg.policies)
	mut pipelines := []runtime_plan.PipelinePlan{cap: cfg.pipelines.len}
	mut pipeline_ids := map[string]bool{}
	for spec in cfg.pipelines {
		if spec.id.trim_space() == '' {
			return error('runtime_plan_pipeline_missing_id')
		}
		if spec.id in pipeline_ids {
			return error('runtime_plan_duplicate_pipeline:${spec.id}')
		}
		pipeline_ids[spec.id] = true
		pipelines << runtime_plan.PipelinePlan{
			id:         spec.id
			group:      spec.group
			ingress:    runtime_plan.parse_ref(spec.ingress)!
			match:      runtime_plan.MatchPlan{
				methods:     spec.match.methods.clone()
				hosts:       spec.match.hosts.clone()
				paths:       spec.match.paths.clone()
				path_regexp: spec.match.path_regexp
				query:       spec.match.query.clone()
				headers:     spec.match.headers.clone()
				metadata:    spec.match.metadata.clone()
			}
			transforms: parse_ref_list(spec.transforms, .transform)!
			policies:   parse_ref_list(spec.policies, .policy)!
			egress:     runtime_plan.parse_ref(spec.egress)!
		}
	}
	mut relays := map[string]runtime_plan.RelayPlan{}
	for id, spec in cfg.relays {
		ingress_ref := parse_optional_ref(spec.listener, .listener)!
		auth_ref := parse_optional_ref(spec.auth, .transform)!
		relays[id] = runtime_plan.RelayPlan{
			id:      id
			mode:    spec.mode
			carrier: spec.carrier
			ingress: ingress_ref.option()
			auth:    auth_ref.option()
			options: runtime_plan.PlanOptions{
				strings: merge_string_options({
					'url':     spec.url
					'path':    spec.path
					'node_id': spec.node_id
					'token':   spec.token
				}, spec.options)
				ints:    nonzero_int_options({
					'max_channels':       spec.max_channels
					'channel_buffer':     spec.channel_buffer
					'reconnect_delay_ms': spec.reconnect_delay_ms
				})
				bools:   {
					'autostart': spec.autostart
				}
			}
		}
	}
	control_listener := parse_optional_ref(cfg.control.listener, .listener)!
	plan := runtime_plan.RuntimePlan{
		source:        runtime_plan.PlanSource{
			schema_version: cfg.version
			config_path:    source_path
			compatibility:  compatibility
		}
		server:        runtime_plan.ServerPlan{
			timezone:            cfg.server.timezone
			pid_file:            cfg.server.pid_file
			shutdown_timeout_ms: cfg.server.shutdown_timeout_ms
		}
		listeners:     listeners
		control:       runtime_plan.ControlPlan{
			listener:        control_listener.option()
			token:           cfg.control.token
			internal_socket: cfg.control.internal_socket
		}
		observability: runtime_plan.ObservabilityPlan{
			event_log: cfg.observability.event_log
			log_level: cfg.observability.log_level
			tracing:   runtime_plan.TracingPlan{
				enabled:     cfg.observability.tracing.enabled
				exporter:    cfg.observability.tracing.exporter
				endpoint:    cfg.observability.tracing.endpoint
				sample_rate: cfg.observability.tracing.sample_rate
			}
		}
		resources:     resources
		engines:       engines
		adapters:      adapters
		transforms:    transforms
		policies:      policies
		pipelines:     pipelines
		relays:        relays
		diagnostics:   diagnostics.clone()
	}
	validate_runtime_plan_references(plan)!
	return plan
}

fn compile_v2_tls_plan(spec V2TlsSpec) runtime_plan.TlsPlan {
	mut certificates := []runtime_plan.TlsCertificatePlan{cap: spec.certificates.len}
	for certificate in spec.certificates {
		certificates << runtime_plan.TlsCertificatePlan{
			hosts:    certificate.hosts.clone()
			cert:     certificate.cert
			cert_key: certificate.cert_key
		}
	}
	return runtime_plan.TlsPlan{
		enabled:      spec.enabled || (spec.cert != '' && spec.cert_key != '')
			|| certificates.len > 0
		cert:         spec.cert
		cert_key:     spec.cert_key
		certificates: certificates
	}
}

struct ParsedOptionalRef {
	present   bool
	reference runtime_plan.ResourceRef
}

fn (parsed ParsedOptionalRef) option() ?runtime_plan.ResourceRef {
	if !parsed.present {
		return none
	}
	return parsed.reference
}

fn parse_optional_ref(value string, expected runtime_plan.RefDomain) !ParsedOptionalRef {
	if value.trim_space() == '' {
		return ParsedOptionalRef{}
	}
	reference := runtime_plan.parse_ref(value)!
	if reference.domain != expected {
		return error('runtime_plan_ref_domain:${value}:expected_${expected}')
	}
	return ParsedOptionalRef{
		present:   true
		reference: reference
	}
}

fn parse_ref_list(values []string, expected runtime_plan.RefDomain) ![]runtime_plan.ResourceRef {
	mut references := []runtime_plan.ResourceRef{cap: values.len}
	for value in values {
		reference := runtime_plan.parse_ref(value)!
		if reference.domain != expected {
			return error('runtime_plan_ref_domain:${value}:expected_${expected}')
		}
		references << reference
	}
	return references
}

fn merge_string_options(base map[string]string, extra map[string]string) map[string]string {
	mut values := nonempty_string_options(base)
	for key, value in extra {
		values[key] = value
	}
	return values
}

fn nonempty_string_options(values map[string]string) map[string]string {
	mut result := map[string]string{}
	for key, value in values {
		if value != '' {
			result[key] = value
		}
	}
	return result
}

fn nonzero_int_options(values map[string]int) map[string]int {
	mut result := map[string]int{}
	for key, value in values {
		if value != 0 {
			result[key] = value
		}
	}
	return result
}

fn merge_int_options(base map[string]int, extra map[string]int) map[string]int {
	mut values := base.clone()
	for key, value in extra {
		values[key] = value
	}
	return values
}

fn compile_v2_db_resources(specs map[string]V2DbResourceSpec, mut resources map[string]runtime_plan.ResourcePlan) {
	for id, spec in specs {
		resources['db/${id}'] = runtime_plan.ResourcePlan{
			id:       'db/${id}'
			category: 'db'
			kind:     spec.kind
			options:  runtime_plan.PlanOptions{
				strings:      merge_string_options({
					'host':     spec.host
					'database': spec.database
					'username': spec.username
					'password': spec.password
				}, spec.options)
				ints:         nonzero_int_options({
					'port':         spec.port
					'pool_size':    spec.pool_size
					'idle_ping_ms': spec.idle_ping_ms
				})
				string_lists: {
					'init_sql': spec.init_sql.clone()
				}
			}
		}
	}
}

fn compile_v2_cache_resources(specs map[string]V2CacheResourceSpec, mut resources map[string]runtime_plan.ResourcePlan) {
	for id, spec in specs {
		resources['cache/${id}'] = runtime_plan.ResourcePlan{
			id:       'cache/${id}'
			category: 'cache'
			kind:     spec.kind
			options:  runtime_plan.PlanOptions{
				strings: merge_string_options({
					'socket':    spec.socket
					'url':       spec.url
					'namespace': spec.namespace
				}, spec.options)
			}
		}
	}
}

fn compile_v2_storage_resources(specs map[string]V2StorageResourceSpec, mut resources map[string]runtime_plan.ResourcePlan) {
	for id, spec in specs {
		resources['storage/${id}'] = runtime_plan.ResourcePlan{
			id:       'storage/${id}'
			category: 'storage'
			kind:     spec.kind
			options:  runtime_plan.PlanOptions{
				strings: merge_string_options({
					'root':   spec.root
					'bucket': spec.bucket
				}, spec.options)
			}
		}
	}
}

fn compile_v2_secret_resources(specs map[string]V2SecretResourceSpec, mut resources map[string]runtime_plan.ResourcePlan) {
	for id, spec in specs {
		resources['secret/${id}'] = runtime_plan.ResourcePlan{
			id:       'secret/${id}'
			category: 'secret'
			kind:     spec.kind
			options:  runtime_plan.PlanOptions{
				strings: merge_string_options({
					'source': spec.source
				}, spec.options)
			}
		}
	}
}

fn compile_v2_engine_options(spec V2EngineSpec) runtime_plan.PlanOptions {
	return runtime_plan.PlanOptions{
		strings:      merge_string_options({
			'entry':           spec.entry
			'app':             spec.app
			'binary':          spec.binary
			'module_root':     spec.module_root
			'build_root':      spec.build_root
			'runtime_profile': spec.runtime_profile
			'socket':          spec.socket
			'socket_prefix':   spec.socket_prefix
			'signature_root':  spec.signature_root
		}, spec.options)
		ints:         nonzero_int_options({
			'pool_size':              spec.pool_size
			'thread_count':           spec.thread_count
			'queue_capacity':         spec.queue_capacity
			'queue_timeout_ms':       spec.queue_timeout_ms
			'read_timeout_ms':        spec.read_timeout_ms
			'restart_backoff_ms':     spec.restart_backoff_ms
			'restart_backoff_max_ms': spec.restart_backoff_max_ms
			'max_requests':           spec.max_requests
		})
		bools:        {
			'autostart':          spec.autostart
			'stream_dispatch':    spec.stream_dispatch
			'websocket_dispatch': spec.websocket_dispatch
			'enable_fs':          spec.enable_fs
			'enable_process':     spec.enable_process
			'enable_network':     spec.enable_network
		}
		string_lists: {
			'args':              spec.args.clone()
			'extensions':        spec.extensions.clone()
			'sockets':           spec.sockets.clone()
			'signature_include': spec.signature_include.clone()
			'signature_exclude': spec.signature_exclude.clone()
		}
		string_maps:  {
			'env': spec.env.clone()
		}
	}
}

fn compile_v2_adapter_options(spec V2AdapterSpec) runtime_plan.PlanOptions {
	return runtime_plan.PlanOptions{
		strings:      merge_string_options({
			'document_root':      spec.document_root
			'index':              spec.index
			'root':               spec.root
			'base_url':           spec.base_url
			'completed_pipeline': spec.completed_pipeline
			'topic':              spec.topic
		}, spec.options)
		ints:         merge_int_options(nonzero_int_options({
			'timeout_ms':     spec.timeout_ms
			'max_body_bytes': spec.max_body_bytes
		}), spec.int_options)
		bools:        spec.bool_options.clone()
		string_lists: spec.list_options.clone()
		string_maps:  spec.map_options.clone()
		record_lists: spec.record_options.clone()
	}
}

fn compile_v2_policies(specs V2PolicySpecs) map[string]runtime_plan.PolicyPlan {
	mut policies := map[string]runtime_plan.PolicyPlan{}
	for id, spec in specs.cache {
		policies['cache/${id}'] = runtime_plan.PolicyPlan{
			id:       'cache/${id}'
			category: 'cache'
			kind:     'cache'
			options:  runtime_plan.PlanOptions{
				strings:      nonempty_string_options({
					'cache_control': spec.cache_control
				})
				ints:         nonzero_int_options({
					'ttl_ms': spec.ttl_ms
				})
				string_lists: {
					'bypass_cookie_patterns': spec.bypass_cookie_patterns.clone()
					'ignore_cookie_patterns': spec.ignore_cookie_patterns.clone()
				}
			}
		}
	}
	for id, spec in specs.limits {
		policies['limits/${id}'] = runtime_plan.PolicyPlan{
			id:       'limits/${id}'
			category: 'limits'
			kind:     'limits'
			options:  runtime_plan.PlanOptions{
				ints: nonzero_int_options({
					'max_body_bytes': spec.max_body_bytes
					'timeout_ms':     spec.timeout_ms
					'queue_capacity': spec.queue_capacity
				})
			}
		}
	}
	for id, spec in specs.security {
		policies['security/${id}'] = runtime_plan.PolicyPlan{
			id:       'security/${id}'
			category: 'security'
			kind:     'security'
			options:  runtime_plan.PlanOptions{
				string_lists: {
					'allowed_origins': spec.allowed_origins.clone()
				}
				string_maps:  {
					'required_headers':      spec.required_headers.clone()
					'denied_query_patterns': spec.denied_query_patterns.clone()
				}
			}
		}
	}
	for id, spec in specs.response {
		policies['response/${id}'] = runtime_plan.PolicyPlan{
			id:       'response/${id}'
			category: 'response'
			kind:     'response'
			options:  runtime_plan.PlanOptions{
				string_maps: {
					'headers': spec.headers.clone()
				}
			}
		}
	}
	for id, spec in specs.retry {
		policies['retry/${id}'] = runtime_plan.PolicyPlan{
			id:       'retry/${id}'
			category: 'retry'
			kind:     'retry'
			options:  runtime_plan.PlanOptions{
				ints: nonzero_int_options({
					'max_attempts':   spec.max_attempts
					'backoff_ms':     spec.backoff_ms
					'max_backoff_ms': spec.max_backoff_ms
				})
			}
		}
	}
	for id, spec in specs.concurrency {
		policies['concurrency/${id}'] = runtime_plan.PolicyPlan{
			id:       'concurrency/${id}'
			category: 'concurrency'
			kind:     'concurrency'
			options:  runtime_plan.PlanOptions{
				strings:      merge_string_options({
					'affinity_source':   spec.affinity_source
					'affinity_key':      spec.affinity_key
					'affinity_scope':    spec.affinity_scope
					'affinity_fallback': spec.affinity_fallback
					'actor_fallback':    spec.actor_fallback
				}, spec.options)
				ints:         nonzero_int_options({
					'max_in_flight':     spec.max_in_flight
					'queue_capacity':    spec.queue_capacity
					'queue_timeout_ms':  spec.queue_timeout_ms
					'max_queue_per_key': spec.max_queue_per_key
				})
				bools:        {
					'affinity_enabled': spec.affinity_enabled
					'actor_enabled':    spec.actor_enabled
				}
				string_lists: {
					'events': spec.events.clone()
				}
				record_lists: spec.record_options.clone()
			}
		}
	}
	return policies
}

fn validate_runtime_plan_references(plan runtime_plan.RuntimePlan) ! {
	if listener := plan.control.listener {
		validate_plan_ref_exists(listener, plan)!
	}
	for _, engine in plan.engines {
		for reference in engine.resources {
			validate_plan_ref_exists(reference, plan)!
		}
	}
	for _, adapter in plan.adapters {
		if engine := adapter.engine {
			validate_plan_ref_exists(engine, plan)!
		}
		if storage := adapter.storage {
			validate_plan_ref_exists(storage, plan)!
		}
	}
	for _, transform in plan.transforms {
		if engine := transform.engine {
			validate_plan_ref_exists(engine, plan)!
		}
	}
	for pipeline in plan.pipelines {
		validate_plan_ref_exists(pipeline.ingress, plan)!
		for reference in pipeline.transforms {
			validate_plan_ref_exists(reference, plan)!
		}
		for reference in pipeline.policies {
			validate_plan_ref_exists(reference, plan)!
		}
		validate_plan_ref_exists(pipeline.egress, plan)!
	}
	for _, relay in plan.relays {
		if ingress := relay.ingress {
			validate_plan_ref_exists(ingress, plan)!
		}
		if auth := relay.auth {
			validate_plan_ref_exists(auth, plan)!
		}
	}
	validate_adapter_semantics(plan)!
	validate_engine_semantics(plan)!
	validate_transform_semantics(plan)!
	validate_listener_pipeline_coverage(plan)!
}

fn validate_plan_ref_exists(reference runtime_plan.ResourceRef, plan runtime_plan.RuntimePlan) ! {
	exists := match reference.domain {
		.listener { reference.id in plan.listeners }
		.resource { reference.id in plan.resources }
		.engine { reference.id in plan.engines }
		.adapter { reference.id in plan.adapters }
		.transform { reference.id in plan.transforms }
		.policy { reference.id in plan.policies }
		.pipeline { plan.pipeline(reference.id) != none }
		.relay { reference.id in plan.relays }
		.terminal { true }
	}

	if !exists {
		return error('runtime_plan_unresolved_ref:${reference}')
	}
}

fn validate_adapter_semantics(plan runtime_plan.RuntimePlan) ! {
	for id, adapter in plan.adapters {
		match adapter.kind {
			'http-handler' {
				if adapter.engine == none {
					return error('runtime_plan_adapter_missing_engine:${id}')
				}
			}
			'static', 'upload' {
				if !plan.source.compatibility && adapter.storage == none
					&& adapter.options.strings['root'].trim_space() == '' {
					return error('runtime_plan_adapter_missing_storage:${id}')
				}
			}
			'fixed-response' {
				if adapter.options.strings['status'].trim_space() == ''
					&& adapter.options.strings['body'].trim_space() == ''
					&& adapter.options.strings['location'].trim_space() == '' {
					return error('runtime_plan_adapter_empty_fixed_response:${id}')
				}
			}
			else {}
		}
	}
}

fn validate_engine_semantics(plan runtime_plan.RuntimePlan) ! {
	for id, engine in plan.engines {
		match engine.kind {
			'php-worker', 'php_worker' {
				if !plan.source.compatibility && engine.options.strings['entry'].trim_space() == ''
					&& engine.options.strings['app'].trim_space() == '' {
					return error('runtime_plan_engine_missing_entry:${id}')
				}
			}
			'php-cgi' {}
			'vjsx' {
				if !plan.source.compatibility && engine.options.strings['entry'].trim_space() == '' {
					return error('runtime_plan_engine_missing_entry:${id}')
				}
			}
			else {
				return error('runtime_plan_engine_unknown_kind:${id}:${engine.kind}')
			}
		}
	}
}

fn validate_transform_semantics(plan runtime_plan.RuntimePlan) ! {
	for id, transform in plan.transforms {
		match transform.kind {
			'native' {}
			'vjsx' {
				if transform.engine == none {
					return error('runtime_plan_transform_missing_engine:${id}')
				}
			}
			else {
				return error('runtime_plan_transform_unknown_kind:${id}:${transform.kind}')
			}
		}

		if transform.handler.trim_space() == '' {
			return error('runtime_plan_transform_missing_handler:${id}')
		}
	}
}

fn validate_listener_pipeline_coverage(plan runtime_plan.RuntimePlan) ! {
	for listener_id, _ in plan.listeners {
		mut found := false
		if control_listener := plan.control.listener {
			if control_listener.domain == .listener && control_listener.id == listener_id {
				found = true
			}
		}
		for _, relay in plan.relays {
			if ingress := relay.ingress {
				if ingress.domain == .listener && ingress.id == listener_id {
					found = true
					break
				}
			}
		}
		for pipeline in plan.pipelines {
			if pipeline.ingress.domain == .listener && pipeline.ingress.id == listener_id {
				found = true
				break
			}
		}
		if !found {
			return error('runtime_plan_listener_without_pipeline:${listener_id}')
		}
	}
}
