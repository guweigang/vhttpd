module provider

import x.json2
import command

// Type aliases for routing types now owned by the command module.
pub type ProviderRouteKind = command.ProviderRouteKind

pub type CommandMatcherKind = command.CommandMatcherKind

pub type CommandMatcher = command.CommandMatcher

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

pub struct ProviderInstanceRegistry {
pub mut:
	specs map[string]ProviderInstanceSpec
}

pub struct ProviderInstanceStore {}

pub fn ProviderInstanceSpec.normalize_instance_name(instance string) string {
	name := instance.trim_space()
	if name == '' || name == 'default' {
		return 'main'
	}
	return name
}

pub fn ProviderInstanceSpec.key_for(provider_name string, instance string) string {
	return '${provider_name.trim_space()}/${ProviderInstanceSpec.normalize_instance_name(instance)}'
}

pub fn (spec ProviderInstanceSpec) normalized_provider() string {
	return spec.provider.trim_space()
}

pub fn (spec ProviderInstanceSpec) normalized_instance() string {
	return ProviderInstanceSpec.normalize_instance_name(spec.instance)
}

pub fn (spec ProviderInstanceSpec) key() string {
	return ProviderInstanceSpec.key_for(spec.provider, spec.instance)
}

pub fn (spec ProviderInstanceSpec) desired_state_or_default() string {
	desired_state := spec.desired_state.trim_space()
	if desired_state == '' {
		return 'connected'
	}
	return desired_state
}

pub fn (spec ProviderInstanceSpec) config_fields() []string {
	raw := spec.config_json.trim_space()
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
