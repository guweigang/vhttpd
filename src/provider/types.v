module provider

import x.json2

// ProviderRouteKind classifies upstream routing targets for the command executor.
pub enum ProviderRouteKind {
	codex
	feishu
	openai
	ollama
	generic
}

// CommandMatcherKind describes how a command matcher compares against a command type.
pub enum CommandMatcherKind {
	prefix
	exact
}

pub struct CommandMatcher {
pub:
	kind  CommandMatcherKind
	value string
}

pub fn (m CommandMatcher) matches(command_type string) bool {
	if m.value.trim_space() == '' {
		return false
	}
	return match m.kind {
		.prefix { command_type.starts_with(m.value) }
		.exact { command_type == m.value }
	}
}

// Admin snapshot types for provider visibility.
pub struct AdminProviderSpecSnapshot {
pub:
	name             string
	enabled          bool
	has_handler      bool     @[json: 'has_handler']
	has_runtime      bool     @[json: 'has_runtime']
	command_matchers []string @[json: 'command_matchers']
	route_kind       string   @[json: 'route_kind']
}

pub struct AdminProviderRuntimeSnapshot {
pub:
	name     string
	enabled  bool
	snapshot string
}

// ProviderInstanceSpec stores an instance's desired configuration.
pub struct ProviderInstanceSpec {
pub mut:
	provider      string
	instance      string
	config_json   string
	desired_state string
	created_at    i64
	updated_at    i64
}

// AdminProviderInstanceSnapshot exposes instance state for admin APIs.
pub struct AdminProviderInstanceSnapshot {
pub:
	provider           string
	instance           string
	source             string
	stored             bool
	runtime_configured bool     @[json: 'runtime_configured']
	runtime_connected  bool     @[json: 'runtime_connected']
	runtime_url        string   @[json: 'runtime_url']
	config_present     bool     @[json: 'config_present']
	config_fields      []string @[json: 'config_fields']
	desired_state      string   @[json: 'desired_state']
	created_at         i64      @[json: 'created_at']
	updated_at         i64      @[json: 'updated_at']
}

// normalize_instance_name canonicalizes an instance identifier.
pub fn normalize_instance_name(instance string) string {
	name := instance.trim_space()
	if name == '' || name == 'default' {
		return 'main'
	}
	return name
}

// instance_key produces a compound key from provider and instance names.
pub fn instance_key(provider_name string, instance string) string {
	return '${provider_name.trim_space()}/${normalize_instance_name(instance)}'
}

// instance_config_fields extracts top-level keys from a JSON config blob.
pub fn instance_config_fields(config_json string) []string {
	raw := config_json.trim_space()
	if raw == '' {
		return []string{}
	}
	parsed := json2.decode[json2.Any](raw) or { return []string{} }
	root := parsed.as_map()
	mut fields := []string{}
	for key, _ in root {
		fields << key
	}
	fields.sort()
	return fields
}
