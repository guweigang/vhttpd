module devmcp

import host

fn test_remote_targets_only_expose_safe_fields_and_matching_live_state() ! {
	profile := host.RemoteProfile{
		id:            'target'
		name:          'Staging'
		server_id:     'host'
		runtime_id:    'package'
		config_path:   '/private/config.toml'
		token:         'private-admin-token'
		identity_file: '/private/key'
	}
	inventory := ManagementTargets{
		servers:  [host.RemoteServer{ id: 'host', name: 'Server', ssh_host: 'private-hostname' }]
		profiles: [profile]
		server:   host.ServerSnapshot{ server_id: 'host', connected: true, runtimes: [host.RemoteRuntime{ id: 'package', version: '0.9.0' }] }
		runtime:  host.RemoteSnapshot{ profile_id: 'different-target', connected: true, instance: host.RemoteInstance{ ready: true } }
	}
	report := inventory.report('targets_list', '')!
	assert report.contains('Staging')
	for value in ['private-admin-token', '/private/config.toml', '/private/key', 'private-hostname'] {
		assert !report.contains(value)
	}
	status := inventory.target(profile)
	assert status.host_connected
	assert status.runtime_version == '0.9.0'
	assert !status.runtime_connected
	assert !status.ready
	assert !status.applications_known
}

fn test_operations_filter_by_connected_server_and_target_path() ! {
	profile := host.RemoteProfile{ id: 'target', server_id: 'host', config_path: '/private/project.toml' }
	inventory := ManagementTargets{
		profiles: [profile,
			host.RemoteProfile{ id: 'other', server_id: 'different-host', config_path: '/private/project.toml' }]
		server:   host.ServerSnapshot{
			server_id:   'host'
			connected:   true
			deployments: [
				host.ApplicationDeploymentStatus{ id: 'release', config_path: profile.config_path, phase: 'rolled_back', error: 'private failure details' },
				host.ApplicationDeploymentStatus{ id: 'unregistered', config_path: '/unregistered/project.toml', phase: 'completed' },
			]
			upgrades:    [host.RemoteRuntimeUpgrade{ id: 'upgrade', config_path: profile.config_path, phase: 'starting' }]
		}
	}
	assert inventory.operations(inventory.profiles[1]).len == 0
	assert inventory.operation_status('release')! == '{"id":"release","target_id":"target","kind":"application_release","phase":"rolled_back","finished":true,"recovery":"restored"}'
	assert inventory.operation_status('upgrade')!.contains('"finished":false')
	if _ := inventory.operation_status('unregistered') {
		return error('unregistered target operation was exposed')
	}
}

fn test_capability_coverage_contains_every_registered_tool_and_explicit_gaps() {
	mut entries := []CapabilityEntry{}
	for spec in development_tool_specs() { entries << capability_entry(spec, '', false) }
	for spec in management_tool_specs() { entries << capability_entry(spec, '', true) }
	coverage := capability_coverage(entries)
	for entry in entries {
		assert entry.domain != 'unclassified', entry.id
		assert coverage.filter(it.id == entry.domain)[0].tools.contains(entry.id), entry.id
	}
	assert coverage.filter(it.id == 'remote_management')[0].state == 'partial'
	assert coverage.filter(it.id == 'runtime_packages')[0].remaining.len == 0
}
