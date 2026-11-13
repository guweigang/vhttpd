module host

import os

fn inventory_fixture(root string) !string {
	os.mkdir_all(root + '/nested')!
	os.write_file(root + '/vhttpd.toml', 'version=2\ninclude=["nested/apps.toml"]\n[listeners.admin]\nprotocol="http"\ntransport="tcp"\nhost="127.0.0.1"\nport=28999\n[control]\nlistener="listener:admin"\ntoken="fixture"\n')!
	os.write_file(root + '/nested/apps.toml', '[listeners.alpha]\nprotocol="http"\ntransport="tcp"\nhost="127.0.0.1"\nport=28001\n[listeners.beta]\nprotocol="http"\ntransport="tcp"\nhost="127.0.0.1"\nport=28002\n[adapters.reply]\nkind="fixed-response"\noptions.body="ok"\n[[pipelines]]\nid="alpha.http"\ngroup="alpha"\ningress="listener:alpha"\negress="adapter:reply"\n[[pipelines]]\nid="beta.http"\ngroup="beta"\ningress="listener:beta"\negress="adapter:reply"\n')!
	return root + '/vhttpd.toml'
}

fn test_stopped_environment_lists_configured_apps_without_a_runtime() ! {
	root := os.join_path(os.temp_dir(), 'offline_apps_${os.getpid()}')
	defer { os.rmdir_all(root) or {} }
	path := inventory_fixture(root)!
	mut manager := Manager{ project: Project{ config_path: path, workdir: root } }
	manager.tick()
	snapshot := manager.snapshot()
	assert snapshot.phase == .stopped && snapshot.pid == 0
	assert snapshot.workspace.applications_available() && snapshot.workspace.from_configuration
	assert !snapshot.workspace.known
	assert snapshot.workspace.applications.map(it.id) == ['alpha', 'beta']
	assert snapshot.workspace.applications.all(it.status == 'configured')
	assert !snapshot.workspace.websocket_known
	assert snapshot.workspace.events.len == 0 && snapshot.workspace.application_logs.len == 0
	assert snapshot.workspace.applications[0].listeners[0].port == 28001
	assert snapshot.workspace.applications[1].pipelines[0].id == 'beta.http'
	// A fresh snapshot after files change must not retain removed installations.
	os.write_file(root + '/nested/apps.toml', '')!
	manager.configured_next_probe = 0
	manager.tick()
	assert manager.snapshot().workspace.applications_available()
	assert manager.snapshot().workspace.applications.len == 0
	os.rm(root + '/nested/apps.toml')!
	manager.configured_next_probe = 0
	manager.tick()
	assert !manager.snapshot().workspace.applications_available()
	assert manager.snapshot().workspace.error != ''
	assert manager.snapshot().workspace.applications.len == 0
}

fn test_failed_environment_keeps_inventory_but_running_projection_wins() ! {
	root := os.join_path(os.temp_dir(), 'offline_apps_failed_${os.getpid()}')
	defer { os.rmdir_all(root) or {} }
	path := inventory_fixture(root)!
	mut manager := Manager{ phase: .failed, project: Project{ config_path: path, workdir: root } }
	manager.tick()
	assert manager.snapshot().workspace.applications.len == 2
	manager.phase = .running
	manager.workspace = RuntimeWorkspace{ known: true, applications: [RuntimeApplication{ id: 'effective' }] }
	assert !manager.snapshot().workspace.from_configuration
	assert manager.snapshot().workspace.applications[0].id == 'effective'
	manager.phase = .stopped
	assert manager.snapshot().workspace.applications.map(it.id) == ['alpha', 'beta']
}
