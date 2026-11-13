module main

import host

fn test_sidebar_versions_follow_instance_then_its_bound_package() {
	mut app := Workshop{
		server_snapshot: host.ServerSnapshot{
			server_id: 'bullsoft'
			runtimes: [host.RemoteRuntime{id: 'old', version: '0.1.0'}, host.RemoteRuntime{id: 'new', version: '0.2.0'}]
			projects: [host.RemoteProfile{id: 'bodytest', server_id: 'bullsoft', runtime_id: 'new'}]
		}
	}
	profile := host.RemoteProfile{id: 'bodytest', server_id: 'bullsoft', runtime_id: 'old'}
	assert app.remote_environment_version(profile) == '0.2.0'
	assert app.remote_environment_version(host.RemoteProfile{id: 'other', server_id: 'bullsoft', runtime_id: 'old'}) == '0.1.0'
	assert app.remote_environment_version(host.RemoteProfile{id: 'elsewhere', server_id: 'another-server', runtime_id: 'old'}) == ''
	assert app.remote_environment_version(host.RemoteProfile{id: 'unknown', server_id: 'bullsoft'}) == ''
	app.remote_snapshot = host.RemoteSnapshot{profile_id: profile.id, connected: true, instance: host.RemoteInstance{version: '0.3.0'}}
	assert app.remote_environment_version(profile) == '0.3.0'
	assert app.remote_environment_version(host.RemoteProfile{id: 'other', server_id: 'bullsoft', runtime_id: 'old'}) == '0.1.0'
}

fn test_sidebar_local_version_and_unknown_version_labels() {
	mut app := Workshop{runtime_info: host.RuntimeInfo{ready: true, version: '0.2.0'}}
	assert environment_runtime_badge(app.local_environment_version(), '运行中') == 'vhttpd 0.2.0 · 运行中'
	app.runtime_info = host.RuntimeInfo{version: '0.1.0', ready: false}
	assert environment_runtime_badge(app.local_environment_version(), '配置入口') == '版本待确认 · 配置入口'
	assert environment_runtime_badge('', '未连接') == '版本待确认 · 未连接'
}
