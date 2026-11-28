module devmcp

import host
import json2 as json

pub struct ManagementTargets {
pub:
	local host.Snapshot
	worker   host.ServerWorker
	servers  []host.RemoteServer
	profiles []host.RemoteProfile
	server   host.ServerSnapshot
	runtime  host.RemoteSnapshot
}

struct ManagementInventory {
	hosts   []ManagementHost
	targets []ManagementTarget
}

struct ManagementHost {
	id        string
	name      string
	connected bool
}

struct ManagementTarget {
	id                 string
	name               string
	host_id            string
	runtime_id         string
	runtime_version    string
	runtime_packages   []ManagementRuntimePackage
	host_connected     bool
	runtime_connected  bool
	ready              bool
	applications_known bool
	applications       []ManagementApplication
	operations         []ManagementOperation
}

struct ManagementRuntimePackage {
	id          string
	version     string
	release_tag string
}

struct ManagementOperation {
	id        string
	target_id string
	kind      string
	phase     string
	finished  bool
	recovery  string
}

struct ManagementApplication {
	id    string
	label string
}

fn (inventory &ManagementTargets) target(profile host.RemoteProfile) ManagementTarget {
	host_connected := profile.server_id != '' && inventory.server.connected
		&& inventory.server.server_id == profile.server_id
	runtime_connected := inventory.runtime.connected && inventory.runtime.profile_id == profile.id
	known := runtime_connected && inventory.runtime.workspace.applications_available()
	mut version := ''
	if runtime_connected {
		version = inventory.runtime.instance.version
	} else if host_connected {
		for runtime in inventory.server.runtimes {
			if runtime.id == profile.runtime_id {
				version = runtime.version
				break
			}
		}
	}
	return ManagementTarget{
		operations:         inventory.operations(profile)
		id:                 profile.id
		name:               profile.name
		host_id:            profile.server_id
		runtime_id:         profile.runtime_id
		runtime_version:    version
		runtime_packages:   if host_connected {
			inventory.server.runtimes.map(ManagementRuntimePackage{ id: it.id, version: it.version, release_tag: it.release_tag })
		} else {
			[]ManagementRuntimePackage{}
		}
		host_connected:     host_connected
		runtime_connected:  runtime_connected
		ready:              runtime_connected && inventory.runtime.instance.ready
		applications_known: known
		applications:       if known {
			inventory.runtime.workspace.applications.map(ManagementApplication{ id: it.id, label: it.label })
		} else {
			[]ManagementApplication{}
		}
	}
}

fn (inventory &ManagementTargets) report(tool string, target_id string) !string {
	if tool == 'target_status' {
		for profile in inventory.profiles {
			if profile.id == target_id {
				return json.encode(inventory.target(profile))
			}
		}
		return error('unknown_target: call targets_list')
	}
	return json.encode(ManagementInventory{
		hosts:   inventory.servers.map(ManagementHost{
			id:        it.id
			name:      it.name
			connected: inventory.server.connected && inventory.server.server_id == it.id
		})
		targets: inventory.profiles.map(inventory.target(it))
	})
}

// The server worker discovers persisted status records after reconnecting.
fn (inventory &ManagementTargets) operations(profile host.RemoteProfile) []ManagementOperation {
	mut result := []ManagementOperation{}
	if !inventory.server.connected || profile.server_id == ''
		|| profile.server_id != inventory.server.server_id || profile.config_path == '' {
		return result
	}
	for deployment in inventory.server.deployments {
		if deployment.config_path == profile.config_path && deployment.id != '' {
			result << ManagementOperation{
				id:        deployment.id
				target_id: profile.id
				kind:      'application_release'
				phase:     deployment.phase
				finished:  deployment.finished()
				recovery:  operation_recovery(deployment.phase)
			}
		}
	}
	for upgrade in inventory.server.upgrades {
		if upgrade.config_path == profile.config_path && upgrade.id != '' {
			result << ManagementOperation{
				id:        upgrade.id
				target_id: profile.id
				kind:      'runtime_upgrade'
				phase:     upgrade.phase
				finished:  upgrade.finished()
				recovery:  operation_recovery(upgrade.phase)
			}
		}
	}
	return result
}

fn operation_recovery(phase string) string {
	return match phase {
		'rolling_back' { 'in_progress' }
		'rolled_back' { 'restored' }
		'rollback_failed' { 'needs_attention' }
		else { 'not_reported' }
	}
}

fn (inventory &ManagementTargets) operation_status(id string) !string {
	if id == '' {
		return error('operation_id_required')
	}
	for profile in inventory.profiles {
		for operation in inventory.operations(profile) {
			if operation.id == id {
				return json.encode(operation)
			}
		}
	}
	return error('unknown_operation: connect the original host in Desktop and call target_status')
}
