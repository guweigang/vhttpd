module main

import host
import json2 as json
import net
import net.http
import os
import time

struct StatusSmokeFile {
	path string
	original string
	value string
}

struct StatusSmokeBundle {
	config_path string
	files []StatusSmokeFile
}

fn run_status_smoke(root string) ! {
	dir := os.join_path(os.real_path(os.temp_dir()), 'vhttpd-status-smoke-${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := listener.addr()!.port()!
	mut web_listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	web_port := web_listener.addr()!.port()!
	web_listener.close()!
	listener.close()!
	path := os.join_path(dir, 'vhttpd.toml')
	relay := os.join_path(dir, 'relay.toml')
	before := '[relays.edge]\nmode="agent"\ncarrier="websocket"\nurl="ws://127.0.0.1:1/vhttpd/relay"\nnode_id="before"\ntoken="field-secret-before"\nautostart=false\n'
	os.write_file(relay, before)!
	routes := os.join_path(dir, 'routes.toml')
	os.write_file(routes, '[adapters.reply]\nkind="fixed-response"\noptions.body="ok"\n[[pipelines]]\nid="health"\ningress="listener:web"\negress="adapter:reply"\n[[pipelines]]\nid="incoming"\nmatch.paths=["/before"]\ningress="relay:edge"\negress="adapter:reply"\n')!
	original_routes := os.read_file(routes)!
	original_root := 'version=2\ninclude=["relay.toml","routes.toml"]\n[server]\npid_file="${dir}/runtime.pid"\n[listeners.web]\nprotocol="http"\nhost="127.0.0.1"\nport=${web_port}\n[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport=${port}\n[control]\nlistener="listener:admin"\ntoken="status-smoke"\n'
	os.write_file(path, original_root)!
	project := host.Project{name: 'status-smoke', config_path: path, workdir: dir}
	persistent := '--persistent-status-smoke' in os.args
	mut manager := if persistent { host.new_persistent_manager_at(os.join_path(dir, 'vault')) } else { host.new_manager() }
	defer { manager.shutdown() }
	manager.start(project, os.getenv_opt('VHTTPD_DESKTOP_BINARY') or { host.workbench_binary(os.executable(), root) })!
	wait_status_ready(mut manager)!
	assert manager.snapshot().config_status.state == .effective
	if persistent { assert manager.snapshot().recovery_saved, manager.snapshot().config_status.message }
	ready := manager.snapshot()
	base := ready.admin_url.replace('/admin/ui/', '')
	body := json.encode(StatusSmokeBundle{config_path: path, files: [StatusSmokeFile{path: relay, original: before, value: before.replace('before', 'after')}, StatusSmokeFile{path: routes, original: original_routes, value: original_routes.replace('/before', '/after')}]})
	for suffix in ['/admin/config/changesets?id=host-status', '/admin/config/changesets/host-status/validate', '/admin/config/changesets/host-status/publish'] {
		mut req := http.Request{method: .post, url: base + suffix, data: if suffix.contains('?') { body } else { '' }}
		req.add_custom_header('x-vhttpd-admin-token', ready.token)!
		response := req.do()!
		assert response.status_code == 200, response.body
		result := json.decode[json.Any](response.body)!.as_map()
		ok := result['ok'] or { return error('missing publication result') }
		assert ok.bool(), response.body
	}
	deadline := time.ticks() + 6000
	for manager.snapshot().config_status.state != .pending && time.ticks() < deadline {
		manager.tick()
		time.sleep(70 * time.millisecond)
	}
	assert manager.snapshot().config_status.state == .pending
	assert manager.snapshot().config_status.message.contains('edge')
	status := manager.snapshot().config_status
	assert status.fields.any(it.kind == 'Relay' && it.field == 'options.node_id' && it.before == '"before"' && it.after == '"after"')
	assert status.fields.any(it.field == 'options.token' && it.redacted && it.before == '[已脱敏]' && it.after == '[已脱敏]')
	assert !status.str().contains('field-secret-before')
	assert !status.str().contains('field-secret-after')
	assert status.files.len == 2
	assert status.files.any(it.path == relay)
	assert status.files.any(it.path == routes && 'incoming' in it.pipelines)
	login := manager.prepare_config_login(relay)!
	assert os.read_file(login)!.contains('#config-source?project=')
	assert !os.read_file(login)!.contains(ready.token)
	mut foreign_rejected := false
	manager.prepare_config_login(os.join_path(dir, 'foreign.toml')) or { foreign_rejected = true }
	assert foreign_rejected

	assert manager.snapshot().config_status.recovery_available
	if persistent {
		manager.shutdown()
		manager = host.new_persistent_manager_at(os.join_path(dir, 'vault'))
		manager.select_project(project)!
		assert manager.snapshot().phase == .stopped
		assert manager.snapshot().recovery_saved
		assert manager.snapshot().config_status.recovery_available
	}
	manager.preview_config_rollback()!
	preview := manager.snapshot().rollback_preview
	assert preview.available && preview.files.len == 2
	assert preview.fields.any(it.field == 'options.node_id' && it.before == '"after"' && it.after == '"before"')
	assert !preview.str().contains('field-secret-')
	// Preview must leave both published files untouched.
	assert os.read_file(relay)! == before.replace('before', 'after')
	assert os.read_file(routes)! != original_routes
	manager.restore_config_rollback(preview.id)!
	assert os.read_file(relay)! == before
	assert os.read_file(routes)! == original_routes
	if persistent {
		assert manager.snapshot().config_status.state != .effective
		manager.start(project, os.getenv_opt('VHTTPD_DESKTOP_BINARY') or { host.workbench_binary(os.executable(), root) })!
		wait_status_ready(mut manager)!
	}
	assert manager.snapshot().config_status.state == .effective
	assert !manager.snapshot().config_status.pending
	assert manager.snapshot().config_status.fields.len == 0
	if !persistent { assert manager.snapshot().message.contains('确认已生效') }
	if persistent { println('PASS: local version history → new host manager → offline cross-include preview/restore → startup full-project effectiveness') }
	println('PASS: cross-include Admin publication → redacted rollback preview → full-project restore → runtime confirmed effective')
	// Retain restart coverage with a subsequent pending edit.
	os.write_file(relay, before.replace('before', 'after'))!
	manager.refresh_config_status()
	assert manager.snapshot().config_status.pending
	assert os.read_file(path)! == original_root
	manager.stop()
	stop_deadline := time.ticks() + 6000
	for manager.snapshot().pid != 0 && time.ticks() < stop_deadline {
		manager.tick()
		time.sleep(50 * time.millisecond)
	}
	assert manager.snapshot().pid == 0
	manager.start(project, os.getenv_opt('VHTTPD_DESKTOP_BINARY') or { host.workbench_binary(os.executable(), root) })!
	wait_status_ready(mut manager)!
	assert manager.snapshot().config_status.state == .effective
	assert !manager.snapshot().config_status.pending
	assert manager.snapshot().config_status.fields.len == 0
	println('PASS: authenticated include publication → automatic pending status → owned restart → automatic effective status; root unchanged')
	if persistent {
		versions := manager.snapshot().recovery_history
		assert versions.len == 2
		first_id := versions.last().id
		second_id := versions[0].id
		manager.compare_history_versions(first_id, second_id)!
		assert manager.snapshot().history_comparison.fields.any(it.field == 'options.node_id')
		assert !manager.snapshot().history_comparison.str().contains('field-secret-')
		manager.preview_history_rollback(first_id)!
		manager.restore_config_rollback(manager.snapshot().rollback_preview.id)!
		assert manager.snapshot().config_status.pending
		manager.shutdown()
		manager = host.new_persistent_manager_at(os.join_path(dir, 'vault'))
		manager.start(project, os.getenv_opt('VHTTPD_DESKTOP_BINARY') or { host.workbench_binary(os.executable(), root) })!
		wait_status_ready(mut manager)!
		assert manager.snapshot().config_status.state == .effective
		assert manager.snapshot().recovery_history.len == 3
		assert manager.snapshot().recovery_history[0].id != first_id
		assert os.read_file(relay)! == before
		assert os.read_file(routes)! == original_routes
		println('PASS: multiple confirmed versions → redacted version comparison → selected historical rollback → pending → owned restart → full-project effective + new history record')
	}
}

fn wait_status_ready(mut manager host.Manager) ! {
	deadline := time.ticks() + 15000
	for manager.snapshot().phase == .starting && time.ticks() < deadline {
		manager.tick()
		time.sleep(60 * time.millisecond)
	}
	s := manager.snapshot()
	if s.phase != .running { return error('${s.message}\n${s.logs}') }
}
