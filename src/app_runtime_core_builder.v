module main

import admin
import server_lifecycle
import time

fn ControlPlaneRuntime.new(build_cfg server_lifecycle.AppRuntimeBuildConfig) ControlPlaneRuntime {
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

fn ProcessLifecycle.started_now() ProcessLifecycle {
	return ProcessLifecycle{
		started_at_unix: time.now().unix()
	}
}
