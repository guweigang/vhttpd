module main

import admin
import config
import server_lifecycle
import time

fn control_plane_runtime_from_build_config(build_cfg server_lifecycle.AppRuntimeBuildConfig) ControlPlaneRuntime {
	return ControlPlaneRuntime{
		event_log:  build_cfg.event_log
		http_stats: HttpStats{}
		admin:      admin.AdminState{
			internal_socket: build_cfg.internal_admin_socket
			on_data_plane:   !build_cfg.admin_enabled
			token:           build_cfg.admin_token
		}
	}
}

fn process_lifecycle_runtime_started_now() ProcessLifecycle {
	return ProcessLifecycle{
		started_at_unix: time.now().unix()
	}
}

fn assets_runtime_from_build_config(build_cfg server_lifecycle.AppRuntimeBuildConfig) config.AssetsRuntime {
	return config.AssetsRuntime{
		enabled:       build_cfg.assets_enabled
		prefix:        build_cfg.assets_prefix
		root:          build_cfg.assets_root
		root_real:     build_cfg.assets_root_real
		cache_control: build_cfg.assets_cache_control
	}
}
