module main

struct AdminSchemaCatalog {
pub:
	version int = 1
	domains []AdminSchemaDomain
}

struct AdminSchemaDomain {
pub:
	id          string
	label       string
	description string
	kinds       []AdminSchemaKind
}

struct AdminSchemaKind {
pub:
	id          string
	label       string
	description string
	fields      []AdminSchemaField
}

struct AdminSchemaField {
pub:
	name        string
	label       string
	type_       string @[json: 'type']
	required    bool
	default     string
	ref_domain  string @[json: 'ref_domain']
	options     []string
	description string
}

fn admin_schema_catalog() AdminSchemaCatalog {
	return AdminSchemaCatalog{
		domains: [
			admin_schema_listeners(),
			admin_schema_resources(),
			admin_schema_engines(),
			admin_schema_adapters(),
			admin_schema_transforms(),
			admin_schema_policies(),
			admin_schema_providers(),
			admin_schema_pipelines(),
			admin_schema_relays(),
		]
	}
}

fn admin_schema_domain(id string) ?AdminSchemaDomain {
	for domain in admin_schema_catalog().domains {
		if domain.id == id {
			return domain
		}
	}
	return none
}

fn admin_schema_kind(domain_id string, kind_id string) ?AdminSchemaKind {
	domain := admin_schema_domain(domain_id) or { return none }
	for kind in domain.kinds {
		if kind.id == kind_id {
			return kind
		}
	}
	return none
}

fn admin_schema_listeners() AdminSchemaDomain {
	return AdminSchemaDomain{
		id:          'listeners'
		label:       'Listeners'
		description: 'Network bind and protocol ingress configuration.'
		kinds:       [
			AdminSchemaKind{
				id:          'http'
				label:       'HTTP Listener'
				description: 'Terminates HTTP traffic and selects HTTP pipelines.'
				fields:      [
					schema_field('protocol', 'Protocol', 'enum', true, 'http', '', [
						'http',
					], 'Listener protocol.'),
					schema_field('transport', 'Transport', 'enum', true, 'tcp', '', [
						'tcp',
					], 'Network transport.'),
					schema_field('host', 'Host', 'string', true, '127.0.0.1', '', [], 'Bind host.'),
					schema_field('port', 'Port', 'int', true, '', '', [], 'Bind port.'),
					schema_field('tls.enabled', 'TLS Enabled', 'bool', false, 'false', '', [],
						'Enable TLS termination.'),
					schema_field('tls.cert', 'TLS Certificate', 'path', false, '', '', [],
						'Default certificate path.'),
					schema_field('tls.cert_key', 'TLS Key', 'path', false, '', '', [],
						'Default certificate key path.'),
				]
			},
			AdminSchemaKind{
				id:          'websocket'
				label:       'WebSocket Listener'
				description: 'Terminates WebSocket traffic.'
				fields:      [
					schema_field('protocol', 'Protocol', 'enum', true, 'websocket', '', [
						'websocket',
					], 'Listener protocol.'),
					schema_field('transport', 'Transport', 'enum', true, 'tcp', '', [
						'tcp',
					], 'Network transport.'),
					schema_field('host', 'Host', 'string', true, '127.0.0.1', '', [], 'Bind host.'),
					schema_field('port', 'Port', 'int', true, '', '', [], 'Bind port.'),
				]
			},
		]
	}
}

fn admin_schema_resources() AdminSchemaDomain {
	return AdminSchemaDomain{
		id:          'resources'
		label:       'Resources'
		description: 'Shared infrastructure dependencies.'
		kinds:       [
			AdminSchemaKind{
				id:          'db'
				label:       'Database'
				description: 'Database resource such as MySQL or PostgreSQL.'
				fields:      [
					schema_field('kind', 'Kind', 'enum', true, 'mysql', '', ['mysql', 'pgsql'],
						'Database driver.'),
					schema_field('host', 'Host', 'string', false, '127.0.0.1', '', [],
						'Database host.'),
					schema_field('port', 'Port', 'int', false, '', '', [], 'Database port.'),
					schema_field('database', 'Database', 'string', false, '', '', [],
						'Database name.'),
					schema_field('username', 'Username', 'string', false, '', '', [],
						'Database user.'),
					schema_field('password', 'Password', 'secret', false, '', '', [],
						'Database password or environment reference.'),
					schema_field('pool_size', 'Pool Size', 'int', false, '', '', [],
						'Connection pool size.'),
					schema_field('idle_ping_ms', 'Idle Ping Milliseconds', 'int', false, '', '',
						[], 'Idle connection ping interval.'),
					schema_field('init_sql', 'Init SQL', 'string_list', false, '', '', [],
						'Statements executed when a connection is initialized.'),
				]
			},
			AdminSchemaKind{
				id:          'cache'
				label:       'Cache'
				description: 'Cache or session store resource.'
				fields:      [
					schema_field('kind', 'Kind', 'enum', true, 'memory', '', ['memory',
						'session-store'], 'Cache implementation.'),
					schema_field('socket', 'Socket', 'path', false, '', '', [],
						'Cache socket path.'),
					schema_field('url', 'URL', 'string', false, '', '', [], 'Remote cache URL.'),
					schema_field('namespace', 'Namespace', 'string', false, '', '', [],
						'Cache namespace.'),
				]
			},
			AdminSchemaKind{
				id:          'storage'
				label:       'Storage'
				description: 'Filesystem or object storage resource.'
				fields:      [
					schema_field('kind', 'Kind', 'enum', true, 'filesystem', '', ['filesystem'],
						'Storage implementation.'),
					schema_field('root', 'Root', 'path', false, '', '', [], 'Filesystem root.'),
					schema_field('bucket', 'Bucket', 'string', false, '', '', [], 'Bucket name.'),
				]
			},
			AdminSchemaKind{
				id:          'secret'
				label:       'Secret'
				description: 'Secret source descriptor.'
				fields:      [
					schema_field('kind', 'Kind', 'enum', true, 'env', '', ['env', 'file'],
						'Secret source kind.'),
					schema_field('source', 'Source', 'string', true, '', '', [], 'Secret source.'),
				]
			},
		]
	}
}

fn admin_schema_engines() AdminSchemaDomain {
	return AdminSchemaDomain{
		id:          'engines'
		label:       'Engines'
		description: 'Application logic runtimes.'
		kinds:       [
			admin_engine_kind('php-worker', 'PHP Worker', true),
			admin_engine_kind('php-cgi', 'PHP CGI', false),
			admin_engine_kind('vjsx', 'VJSX', true),
		]
	}
}

fn admin_engine_kind(id string, label string, entry_required bool) AdminSchemaKind {
	return AdminSchemaKind{
		id:          id
		label:       label
		description: 'Execution runtime configuration.'
		fields:      [
			schema_field('kind', 'Kind', 'enum', true, id, '', [id], 'Engine kind.'),
			schema_field('entry', 'Entry', 'path', entry_required, '', '', [],
				'Runtime entry file.'),
			schema_field('app', 'App', 'path', false, '', '', [], 'Application entry.'),
			schema_field('module_root', 'Module Root', 'path', false, '', '', [],
				'Module root for VJSX.'),
			schema_field('pool_size', 'Pool Size', 'int', false, '', '', [], 'Worker pool size.'),
			schema_field('thread_count', 'Thread Count', 'int', false, '', '', [],
				'VJSX lane/thread count.'),
			schema_field('queue_capacity', 'Queue Capacity', 'int', false, '', '', [],
				'Queue capacity.'),
			schema_field('queue_timeout_ms', 'Queue Timeout', 'int', false, '', '', [],
				'Queue timeout in milliseconds.'),
			schema_field('resources', 'Resources', 'ref_list', false, '', 'resource', [],
				'Resources available to this engine.'),
			schema_field('capabilities', 'Capabilities', 'string_list', false, '', '', [],
				'Declared engine capabilities.'),
		]
	}
}

fn admin_schema_adapters() AdminSchemaDomain {
	return AdminSchemaDomain{
		id:          'adapters'
		label:       'Adapters'
		description: 'Ingress and egress protocol adapters.'
		kinds:       [
			adapter_kind('http-handler', 'HTTP Handler', ['engine', 'document_root', 'index']),
			adapter_kind('static', 'Static Files', ['storage', 'root']),
			adapter_kind('upload', 'Upload', ['storage', 'max_body_bytes', 'completed_pipeline']),
			adapter_kind('http-upstream', 'HTTP Upstream', ['base_url', 'timeout_ms']),
			adapter_kind('fixed-response', 'Fixed Response', ['status', 'body', 'location']),
			adapter_kind('event-ingress', 'Event Ingress', ['topic']),
			adapter_kind('mcp', 'MCP', ['engine']),
			adapter_kind('mcp-upstream', 'MCP Upstream', ['url', 'timeout_ms']),
			adapter_kind('relay-delivery', 'Relay Delivery', ['target', 'route', 'completion_mode',
				'frame_kind', 'completion_timeout_ms']),
			adapter_kind('provider-action', 'Provider Action', ['provider', 'action', 'capability',
				'runtime_driver', 'runtime_plugin', 'runtime_engine']),
		]
	}
}

fn adapter_kind(id string, label string, extra []string) AdminSchemaKind {
	mut fields := [
		schema_field('kind', 'Kind', 'enum', true, id, '', [id], 'Adapter kind.'),
	]
	for name in extra {
		fields << adapter_field(name)
	}
	return AdminSchemaKind{
		id:          id
		label:       label
		description: 'Adapter configuration.'
		fields:      fields
	}
}

fn adapter_field(name string) AdminSchemaField {
	return match name {
		'engine' { schema_field('engine', 'Engine', 'ref', true, '', 'engine', [],
				'Engine reference.') }
		'storage' { schema_field('storage', 'Storage', 'ref', false, '', 'resource', [],
				'Storage resource reference.') }
		'document_root' { schema_field('document_root', 'Document Root', 'path', false, '', '', [],
				'Document root.') }
		'index' { schema_field('index', 'Index', 'string', false, '', '', [], 'Index file.') }
		'root' { schema_field('root', 'Root', 'path', false, '', '', [], 'Filesystem root.') }
		'base_url' { schema_field('base_url', 'Base URL', 'string', true, '', '', [],
				'Upstream base URL.') }
		'timeout_ms' { schema_field('timeout_ms', 'Timeout', 'int', false, '', '', [],
				'Timeout in milliseconds.') }
		'max_body_bytes' { schema_field('max_body_bytes', 'Max Body Bytes', 'int', false, '', '',
				[], 'Maximum request body size.') }
		'completed_pipeline' { schema_field('completed_pipeline', 'Completed Pipeline', 'ref',
				false, '', 'pipeline', [], 'Pipeline called after completion.') }
		'status' { schema_field('options.status', 'Status', 'string', false, '', '', [],
				'HTTP status.') }
		'body' { schema_field('options.body', 'Body', 'text', false, '', '', [], 'Response body.') }
		'location' { schema_field('options.location', 'Location', 'string', false, '', '', [],
				'Redirect location.') }
		'topic' { schema_field('topic', 'Topic', 'string', false, '', '', [], 'Event topic.') }
		'url' { schema_field('options.url', 'URL', 'string', true, '', '', [], 'Upstream URL.') }
		'target' { schema_field('options.target', 'Target', 'ref', true, '', 'relay', [],
				'Relay target.') }
		'route' { schema_field('options.route', 'Route', 'string', false, '', '', [],
				'Relay route.') }
		'completion_mode' { schema_field('options.completion_mode', 'Completion Mode', 'enum',
				false, 'accepted', '', ['accepted', 'wait'], 'Relay completion mode.') }
		'frame_kind' { schema_field('options.frame_kind', 'Frame Kind', 'enum', false, 'open', '', [
				'open',
				'send',
			], 'Relay frame kind.') }
		'completion_timeout_ms' { schema_field('int_options.completion_timeout_ms',
				'Completion Timeout', 'int', false, '', '', [], 'Relay completion timeout.') }
		'provider' { schema_field('provider', 'Provider', 'string', true, '', '', [],
				'Provider id.') }
		'action' { schema_field('action', 'Action', 'string', true, '', '', [], 'Provider action.') }
		'capability' { schema_field('capability', 'Capability', 'string', false, '', '', [],
				'Provider capability.') }
		'runtime_driver' { schema_field('runtime_driver', 'Runtime Driver', 'enum', false,
				'native', '', ['native', 'vjsx'], 'Provider runtime driver.') }
		'runtime_plugin' { schema_field('runtime_plugin', 'Runtime Plugin', 'string', false, '',
				'', [], 'Provider runtime plugin.') }
		'runtime_engine' { schema_field('runtime_engine', 'Runtime Engine', 'ref', false, '',
				'engine', [], 'Provider runtime engine.') }
		else { schema_field(name, name, 'string', false, '', '', [], '') }
	}
}

fn admin_schema_transforms() AdminSchemaDomain {
	return AdminSchemaDomain{
		id:          'transforms'
		label:       'Transforms'
		description: 'Exchange transformation handlers.'
		kinds:       [
			AdminSchemaKind{
				id:          'native'
				label:       'Native Transform'
				description: 'Built-in V transform handler.'
				fields:      transform_fields('native', false)
			},
			AdminSchemaKind{
				id:          'vjsx'
				label:       'VJSX Transform'
				description: 'TypeScript/VJSX transform handler.'
				fields:      transform_fields('vjsx', true)
			},
		]
	}
}

fn transform_fields(kind string, engine_required bool) []AdminSchemaField {
	return [
		schema_field('kind', 'Kind', 'enum', true, kind, '', [kind], 'Transform kind.'),
		schema_field('engine', 'Engine', 'ref', engine_required, '', 'engine', [],
			'Engine reference.'),
		schema_field('handler', 'Handler', 'string', true, '', '', [], 'Handler name.'),
		schema_field('target', 'Target', 'string', false, '', '', [], 'Target pattern.'),
		schema_field('strip_prefix', 'Strip Prefix', 'string', false, '', '', [],
			'Path prefix to strip.'),
	]
}

fn admin_schema_policies() AdminSchemaDomain {
	return AdminSchemaDomain{
		id:          'policies'
		label:       'Policies'
		description: 'Reusable cache, limit, security, response, retry, and concurrency policies.'
		kinds:       [
			policy_kind('cache', ['cache_control', 'ttl_ms']),
			policy_kind('limits', ['max_body_bytes', 'timeout_ms', 'queue_capacity']),
			policy_kind('security', ['required_headers', 'allowed_origins']),
			policy_kind('response', ['headers']),
			policy_kind('retry', ['max_attempts', 'backoff_ms', 'max_backoff_ms']),
			policy_kind('concurrency', ['max_in_flight', 'queue_capacity', 'queue_timeout_ms',
				'affinity_enabled', 'actor_enabled']),
		]
	}
}

fn policy_kind(id string, names []string) AdminSchemaKind {
	mut fields := []AdminSchemaField{}
	for name in names {
		fields << schema_field(name, title_from_key(name), policy_field_type(name), false, '', '',
			[], '')
	}
	return AdminSchemaKind{
		id:          id
		label:       title_from_key(id)
		description: 'Policy configuration.'
		fields:      fields
	}
}

fn admin_schema_providers() AdminSchemaDomain {
	return AdminSchemaDomain{
		id:          'providers'
		label:       'Providers'
		description: 'Provider runtime and hook configuration.'
		kinds:       [
			AdminSchemaKind{
				id:          'runtime'
				label:       'Provider Runtime'
				description: 'Native or VJSX-backed provider runtime.'
				fields:      [
					schema_field('runtime.driver', 'Driver', 'enum', false, 'native', '', [
						'native',
						'vjsx',
					], 'Runtime driver.'),
					schema_field('runtime.protocol', 'Protocol', 'string', true, '', '', [],
						'Transport protocol such as websocket.'),
					schema_field('runtime.plugin', 'Plugin', 'string', false, '', '', [],
						'VJSX plugin module.'),
					schema_field('runtime.engine', 'Engine', 'ref', false, '', 'engine', [],
						'Runtime engine reference.'),
					schema_field('hooks', 'Hooks', 'map', false, '', '', [],
						'Hook name to method map.'),
					schema_field('capabilities', 'Capabilities', 'map', false, '', '', [],
						'Capability map.'),
				]
			},
		]
	}
}

fn admin_schema_pipelines() AdminSchemaDomain {
	return AdminSchemaDomain{
		id:          'pipelines'
		label:       'Pipelines'
		description: 'Ingress match, transforms, policies, and egress flow.'
		kinds:       [
			AdminSchemaKind{
				id:          'pipeline'
				label:       'Pipeline'
				description: 'Protocol pipeline.'
				fields:      [
					schema_field('id', 'ID', 'string', true, '', '', [], 'Pipeline id.'),
					schema_field('group', 'Group', 'string', false, '', '', [],
						'Operational group.'),
					schema_field('ingress', 'Ingress', 'ref', true, '', 'listener,relay,provider',
						[], 'Ingress reference.'),
					schema_field('match.methods', 'Methods', 'string_list', false, '', '', [],
						'HTTP methods.'),
					schema_field('match.hosts', 'Hosts', 'string_list', false, '', '', [],
						'HTTP hosts.'),
					schema_field('match.paths', 'Paths', 'string_list', false, '', '', [],
						'Path patterns.'),
					schema_field('match.path_regexp', 'Path RegExp', 'string', false, '', '', [],
						'Path regular expression.'),
					schema_field('match.path_regexps', 'Path RegExps', 'string_list', false, '',
						'', [], 'Path regular expressions matched with OR semantics.'),
					schema_field('match.query', 'Query', 'map_list', false, '', '', [],
						'Query key constraints. Keys are ANDed, values are ORed.'),
					schema_field('transforms', 'Transforms', 'ref_list', false, '', 'transform',
						[], 'Ordered transform references.'),
					schema_field('policies', 'Policies', 'ref_list', false, '', 'policy', [],
						'Policy references.'),
					schema_field('egress', 'Egress', 'ref', true, '', 'adapter', [],
						'Egress adapter.'),
				]
			},
		]
	}
}

fn admin_schema_relays() AdminSchemaDomain {
	return AdminSchemaDomain{
		id:          'relays'
		label:       'Relays'
		description: 'Cross-node relay endpoints.'
		kinds:       [
			AdminSchemaKind{
				id:          'hub'
				label:       'Relay Hub'
				description: 'Accepts relay carriers from agents.'
				fields:      relay_fields('hub')
			},
			AdminSchemaKind{
				id:          'agent'
				label:       'Relay Agent'
				description: 'Connects to a remote relay hub.'
				fields:      relay_fields('agent')
			},
		]
	}
}

fn relay_fields(mode string) []AdminSchemaField {
	return [
		schema_field('mode', 'Mode', 'enum', true, mode, '', [mode], 'Relay mode.'),
		schema_field('carrier', 'Carrier', 'enum', true, 'websocket', '', ['websocket'],
			'Relay carrier.'),
		schema_field('listener', 'Listener', 'ref', mode == 'hub', '', 'listener', [],
			'Listener reference for hub mode.'),
		schema_field('url', 'URL', 'string', mode == 'agent', '', '', [], 'Hub URL for agent mode.'),
		schema_field('path', 'Path', 'string', false, '/vhttpd/relay', '', [], 'Relay path.'),
		schema_field('node_id', 'Node ID', 'string', false, '', '', [], 'Node id.'),
		schema_field('token', 'Token', 'secret', false, '', '', [], 'Relay auth token.'),
		schema_field('autostart', 'Autostart', 'bool', false, 'false', '', [], 'Autostart agent.'),
		schema_field('max_channels', 'Max Channels', 'int', false, '', '', [], 'Maximum channels.'),
		schema_field('channel_buffer', 'Channel Buffer', 'int', false, '', '', [],
			'Channel buffer size.'),
		schema_field('reconnect_delay_ms', 'Reconnect Delay', 'int', false, '', '', [],
			'Reconnect delay in milliseconds.'),
	]
}

fn schema_field(name string, label string, type_ string, required bool, default string, ref_domain string, options []string, description string) AdminSchemaField {
	return AdminSchemaField{
		name:        name
		label:       label
		type_:       type_
		required:    required
		default:     default
		ref_domain:  ref_domain
		options:     options.clone()
		description: description
	}
}

fn title_from_key(key string) string {
	return key.replace('_', ' ').split(' ').map(it.capitalize()).join(' ')
}

fn policy_field_type(name string) string {
	if name.ends_with('_ms') || name.starts_with('max_') || name == 'queue_capacity' {
		return 'int'
	}
	if name.ends_with('_enabled') {
		return 'bool'
	}
	if name in ['headers', 'required_headers'] {
		return 'map'
	}
	if name == 'allowed_origins' {
		return 'string_list'
	}
	return 'string'
}
