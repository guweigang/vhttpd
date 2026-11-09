module devmcp

import host
import json2 as json
import mcp

struct CapabilityArgs {
	include_runtime  bool
	binding_revision u64
}

struct CapabilityEntry {
	id          string
	domain      string
	description string
	access      string
	available   bool
	reason      string @[omitempty]
}

struct CapabilityCoverage {
	id        string
	state     string
	tools     []string
	remaining []string
	guidance  []string
}

fn capability_coverage(entries []CapabilityEntry) []CapabilityCoverage {
	remaining := {
		'workspace':             []string{}
		'runtime_configuration': ['configuration_secrets_executable_paths_and_source_membership_changes_require_desktop']
		'remote_management':     ['password_host_connection_requires_desktop']
		'relay_management':      []string{}
		'diagnostics':           ['non_bearer_authentication_and_advanced_protocol_probes', 'remote_environment_secret_and_tls_references']
	}
	mut domains := []string{}
	for entry in entries {
		if entry.domain !in domains { domains << entry.domain }
	}
	mut result := []CapabilityCoverage{}
	for domain in domains {
		pending := remaining[domain] or { []string{} }
		result << CapabilityCoverage{
			id:        domain
			state:     if pending.len > 0 { 'partial' } else { 'tools_available' }
			tools:     entries.filter(it.domain == domain).map(it.id)
			remaining: pending
			guidance:  if domain in ['diagnostics', 'traffic_takeover'] {
				['debug']
			} else if domain in ['application_release', 'runtime_packages', 'remote_management',
				'relay_publication', 'relay_management', 'runtime_configuration'] {
				['deploy']
			} else {
				['workflow']
			}
		}
	}
	return result
}

fn capability_domain(name string) string {
	return match name.all_before('_') {
		'capabilities', 'context', 'guidance' { 'discovery' }
		'source', 'project', 'templates', 'files', 'changes' { 'workspace' }
		'schema', 'shared' { 'runtime_configuration' }
		'runtime' {
			if name.starts_with('runtime_upgrade_') || is_package_tool(name) || name in [
				'runtime_package_get',
				'runtime_packages_list',
				'runtime_releases_list',
				'runtime_package_probe',
			] {
				'runtime_packages'
			} else if name == 'runtime_diagnostics_get' {
				'diagnostics'
			} else {
				'runtime_lifecycle'
			}
		}
		'logs', 'config' { 'diagnostics' }
		'application' {
			if name.starts_with('application_install_') || name == 'application_templates_list' {
				'application_setup'
			} else if name.starts_with('application_release_') {
				'application_release'
			} else {
				'application_verification'
			}
		}
		'target' {
			if name in ['target_request', 'target_protocol_probe', 'target_probe_options_get'] {
				'application_verification'
			} else if name in ['target_diagnostics_get', 'target_logs_query', 'target_events_query',
				'target_history_list', 'target_applications_list'] {
				'diagnostics'
			} else {
				'remote_management'
			}
		}
		'targets', 'operation', 'host', 'environment', 'instance' { 'remote_management' }
		'relay' {
			if name == 'relay_connections_list' || is_ordinary_relay_tool(name) {
				'relay_management'
			} else {
				'relay_publication'
			}
		}
		'takeover' { 'traffic_takeover' }
		else { 'unclassified' }
	}
}

fn development_tool_unavailable(spec ToolSpec, bound_application bool, scope RelayScope) string {
	if spec.name.starts_with('source_workspace_') && (!scope.source_workspace || !isnil(scope.grant)) {
		return 'local_source_workspace_session_required'
	}
	if scope.source_workspace && spec.name in ['project_create', 'project_select',
		'application_install_prepare', 'application_install_apply'] {
		return 'source_workspace_uses_binding_tools'
	}

	if bound_application && spec.name in ['project_create', 'project_select',
		'application_install_prepare', 'application_install_apply'] {
		return 'workspace_session_required'
	}
	if !isnil(scope.grant) && spec.name in ['runtime_diagnostics_get', 'runtime_packages_list',
		'runtime_releases_list', 'runtime_package_probe'] {
		return 'local_session_required'
	}
	if !isnil(scope.grant) && !scope.writable && !spec.read_only {
		return 'write_access_required'
	}
	return ''
}

fn development_tool_available(spec ToolSpec, bound_application bool, scope RelayScope) bool {
	return development_tool_unavailable(spec, bound_application, scope) == ''
}

fn management_tools_available(scope RelayScope) bool {
	return scope.calls.cap > 0 && isnil(scope.grant)
}

fn capability_entry(spec ToolSpec, reason string, management bool) CapabilityEntry {
	return CapabilityEntry{
		id:          spec.name
		domain:      capability_domain(spec.name)
		description: spec.description
		access:      if management {
			'management'
		} else if spec.read_only {
			'read'
		} else {
			'write'
		}
		available:   reason == ''
		reason:      reason
	}
}

fn capability_schema_arguments(arguments string) !string {
	args := json.decode[CapabilityArgs](arguments)!
	return json.encode({
		'binding_revision': args.binding_revision
	})
}

fn capability_result(scope RelayScope, bound_application bool, runtime host.DevelopmentReply) !mcp.ToolResult {
	mut entries := []CapabilityEntry{}
	for spec in development_tool_specs() {
		entries << capability_entry(spec, development_tool_unavailable(spec, bound_application, scope), false)
	}
	for spec in management_tool_specs() {
		entries << capability_entry(spec, if management_tools_available(scope) {
			''
		} else {
			'management_session_required'
		}, true)
	}
	mut result := {
		'catalog_version':        json.Any(1)
		'desktop':                json.decode[json.Any](json.encode(entries))!
		'runtime_discovery_tool': json.Any('schema_get')
		'coverage_version':       json.Any(1)
		'coverage':               json.decode[json.Any](json.encode(capability_coverage(entries)))!
		'coverage_status':        json.Any('partial')
		'guidance_topics':        json.decode[json.Any](json.encode(['project', 'develop', 'vjsx',
			'workflow', 'pipeline', 'wechat-cloud-functions', 'codexbot', 'deploy', 'debug']))!
	}
	if runtime.error {
		result['runtime_error'] = json.Any(runtime.value)
	} else if runtime.value != '' {
		result['runtime_schema'] = json.decode[json.Any](runtime.value)!
	}
	return mcp.ToolResult{ content: '[${mcp.text_content(json.encode(result))}]' }
}
