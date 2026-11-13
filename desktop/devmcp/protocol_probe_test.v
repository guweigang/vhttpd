module devmcp

import host
import json2 as json

fn test_protocol_probe_requires_edit_grant_and_valid_tool_schema() ! {
	specs := development_tool_specs().filter(it.name == 'application_protocol_probe')
	assert specs.len == 1
	read_scope := RelayScope{ grant: host.new_development_grant(0), writable: false }
	assert development_tool_unavailable(specs[0], true, read_scope) == 'write_access_required'
	assert development_tool_unavailable(specs[0], true, RelayScope{ grant: host.new_development_grant(0), writable: true }) == ''
	remote := management_tool_specs().filter(it.name == 'target_protocol_probe')
	assert remote.len == 1 && !remote[0].read_only
	properties := json.decode[map[string]json.Any]('{' + remote[0].properties + '}')!
	assert 'protocol' in properties && 'target_id' in properties
	assert 'auth_ref' in properties && 'tls_trust' in properties && 'tls_server_name' in properties
	assert 'insecure' !in properties && 'verify' !in properties && 'ca_file' !in properties
	assert development_tool_specs().filter(it.name == 'application_probe_options_get' && it.read_only).len == 1
	assert management_tool_specs().filter(it.name == 'target_probe_options_get' && it.read_only).len == 1
	assert 'url' !in properties && 'headers' !in properties && 'token' !in properties
	assert capability_domain(remote[0].name) == 'application_verification'
}
