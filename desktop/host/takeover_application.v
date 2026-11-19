module host

import app_bundle
import config
import os

pub struct TakeoverApplicationTarget {
pub:
	binding      ApplicationBinding
	local_engine string
	label        string
}

pub fn takeover_application_targets(path string) ![]TakeoverApplicationTarget {
	bindings := load_application_bindings()!
	servers := load_remote_servers() or { []RemoteServer{} }
	profiles := load_remote_profiles() or { []RemoteProfile{} }
	mut targets := []TakeoverApplicationTarget{}
	plan := config.load_runtime_plan_file(path)!

	for engine, definition in plan.engines {
		if definition.kind != 'vjsx' { continue }
		meta := app_bundle.engine_manifest(path, engine) or { continue }
		for b in bindings {
			if b.phase != 'installed' || b.server_id == '' || b.app_id != meta.id { continue }

			server_name := servers.filter(it.id == b.server_id)
			profile_name := profiles.filter(it.id == b.environment_id && it.server_id == b.server_id)
			location := (if server_name.len == 1 { server_name[0].name } else { b.server_id }) + ' / ' + (if profile_name.len == 1 {
				profile_name[0].name
			} else {
				b.environment_id
			})
			targets << TakeoverApplicationTarget{ binding: b, local_engine: engine, label: b.component + ' · ' + location + ' · ' + b.installation_id[..8] + ' · ' + engine }
		}
	}

	return targets
}

pub fn (target TakeoverApplicationTarget) key() string {
 return target.binding.installation_id + '/' + target.local_engine
}

pub fn project_uses_application_meta(path string) bool {
 sources := config.runtime_config_sources(path) or {return true}
 for source in sources {
  root := app_bundle.application_source_root(source.path,os.dir(path)) or {return true}
  if root != '' {return true}
 }
 return false
}
