module main

import host
import json2 as json
import net
import net.http
import os
import time

fn shared_smoke_port() !int {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := listener.addr()!.port()!
	listener.close()!
	return port
}

fn shared_smoke_call(base string, token string, path string, method http.Method, body string) !http.Response {
	mut request := http.Request{ url: base + path, method: method, data: body, read_timeout: 4 * time.second, write_timeout: 4 * time.second, allow_redirect: false }
	request.add_custom_header('x-vhttpd-admin-token', token)!
	request.add_custom_header('content-type', 'application/json')!
	return request.do()!
}

fn run_shared_relay_smoke(root string) ! {
	dir := os.join_path(os.real_path(os.temp_dir()), 'vhttpd-shared-smoke-${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	binary := os.getenv_opt('VHTTPD_DESKTOP_BINARY') or { host.workbench_binary(os.executable(), root) }
	hub_port := shared_smoke_port()!
	hub_admin := shared_smoke_port()!
	hub_path := os.join_path(dir, 'hub.toml')
	os.write_file(hub_path, 'version=2\n[server]\npid_file="${dir}/hub.pid"\n[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport=${hub_admin}\n[control]\nlistener="listener:admin"\ntoken="hub-admin"\n[listeners.ws]\nprotocol="websocket"\nhost="127.0.0.1"\nport=${hub_port}\n[relays.hub]\nmode="hub"\ncarrier="websocket"\nlistener="listener:ws"\npath="/vhttpd/relay"\nnode_id="hub"\ntoken="shared-smoke-secret"\n')!
	mut hub := host.new_manager()
	defer { hub.shutdown() }
	hub.start(host.Project{ name: 'hub', config_path: hub_path, workdir: dir }, binary)!
	wait_status_ready(mut hub)!
	profile := host.SharedRelay{ relay_id: 'hub', id: host.new_shared_relay_id()!, name: 'test hub', url: 'ws://127.0.0.1:${hub_port}/vhttpd/relay', token: 'shared-smoke-secret' }
	probe := host.probe_shared_relay(profile)
	shared_smoke_expect(probe.ok, probe.stage + ': ' + probe.message)!
	rejected := host.probe_shared_relay(host.SharedRelay{ ...profile, token: 'wrong-private-token' })
	shared_smoke_expect(!rejected.ok && rejected.stage == 'Relay 认证', 'shared Relay acceptance step 41 failed')!
	shared_smoke_expect(!rejected.message.contains('private-token'), 'shared Relay acceptance step 42 failed')!
	shared_smoke_expect(!host.probe_shared_relay(host.SharedRelay{ ...profile, relay_id: 'wrong-hub' }).ok, 'shared Relay acceptance step 43 failed')!
	wrong_path := host.probe_shared_relay(host.SharedRelay{ ...profile, url: 'ws://127.0.0.1:${hub_port}/not-relay' })
	shared_smoke_expect(!wrong_path.ok, 'shared Relay acceptance step 45 failed')!
	tls := host.probe_shared_relay(host.SharedRelay{ ...profile, url: 'wss://127.0.0.1:${hub_port}/vhttpd/relay' })
	shared_smoke_expect(!tls.ok && tls.stage == 'TLS', 'shared Relay acceptance step 47 failed')!
	println('PASS shared Relay: real Hub accepts valid credentials, rejects wrong token/path, TLS errors stay failures, diagnostics redacted')
	admin := shared_smoke_port()!
	web := shared_smoke_port()!
	path := os.join_path(dir, 'project.toml')
	include := os.join_path(dir, 'relay.toml')
	routes := os.join_path(dir, 'routes.toml')
	original := 'version=2\ninclude=["relay.toml","routes.toml"]\n[server]\npid_file="${dir}/project.pid"\n[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport=${admin}\n[control]\nlistener="listener:admin"\ntoken="project-admin"\n[listeners.web]\nprotocol="http"\nhost="127.0.0.1"\nport=${web}\n'
	original_routes := '[adapters.reply]\nkind="fixed-response"\noptions.body="ok"\n[[pipelines]]\nid="health"\ningress="listener:web"\negress="adapter:reply"\n'
	os.write_file(path, original)!
	os.write_file(include, '# shared connection destination\n')!
	os.write_file(routes, original_routes)!
	project := host.Project{ name: 'client', config_path: path, workdir: dir }
	mut manager := host.new_manager()
	defer { manager.shutdown() }
	manager.start(project, binary)!
	wait_status_ready(mut manager)!
	ready := manager.snapshot()
	base := ready.admin_url.replace('/admin/ui/', '')
	login := manager.prepare_shared_relay_login(profile)!
	html := os.read_file(login)!
	shared_smoke_expect(!html.contains(profile.token), 'shared Relay acceptance step 68 failed')!
	id := html.all_after('#relay-draft?id=').all_before('"')
	shared_smoke_expect(id.starts_with('shared-relay-'), 'shared Relay acceptance step 70 failed')!
	shared_smoke_expect(os.read_file(path)! == original, 'shared Relay acceptance step 71 failed')!
	unauthorized := shared_smoke_call(base, 'incorrect', '/admin/config/changesets/${id}', .get, '')!
	shared_smoke_expect(unauthorized.status_code == 403, 'shared Relay acceptance step 73 failed')!
	response := shared_smoke_call(base, ready.token, '/admin/config/changesets/${id}', .get, '')!
	shared_smoke_expect(response.status_code == 200, 'shared Relay acceptance step 75 failed')!
	imported := json.decode[StatusSmokeBundle](response.body)!
	fragment := imported.files[0].value.all_after(original)
	shared_smoke_expect(fragment.contains(profile.url) && fragment.contains('autostart = false'), 'shared Relay acceptance step 78 failed')!
	second_login := manager.prepare_shared_relay_login(profile)!
	second_id := os.read_file(second_login)!.all_after('#relay-draft?id=').all_before('"')
	second := json.decode[StatusSmokeBundle](shared_smoke_call(base, ready.token, '/admin/config/changesets/${second_id}', .get, '')!.body)!
	shared_smoke_expect(second.files[0].value != imported.files[0].value, 'shared Relay acceptance step 82 failed')!
	// Move the new agent to one include and bind its inbound pipeline in another.
	relay_id := fragment.all_after('[relays.').all_before(']')
	route_text := original_routes + '\n[[pipelines]]\nid="remote-incoming"\ningress="relay:${relay_id}"\negress="adapter:reply"\n'
	bundle := StatusSmokeBundle{
		config_path: path
		files:       [
			StatusSmokeFile{ path: include, original: os.read_file(include)!, value: os.read_file(include)! + fragment.replace('autostart = false', 'autostart = true') },
			StatusSmokeFile{ path: routes, original: original_routes, value: route_text },
		]
	}
	shared_smoke_expect(shared_smoke_call(base, ready.token, '/admin/config/changesets?id=${id}', .post, json.encode(bundle))!.status_code == 200, 'project changeset request failed')!
	shared_smoke_expect(shared_smoke_call(base, ready.token, '/admin/config/changesets/${id}/validate', .post, '')!.status_code == 200, 'project changeset request failed')!
	shared_smoke_expect(shared_smoke_call(base, ready.token, '/admin/config/changesets/${id}/publish', .post, '')!.status_code == 200, 'project changeset request failed')!
	manager.refresh_config_status()
	shared_smoke_expect(manager.snapshot().config_status.pending, 'shared Relay acceptance step 97 failed')!
	manager.stop()
	deadline := time.ticks() + 7000
	for manager.snapshot().pid != 0 && time.ticks() < deadline {
		manager.tick()
		time.sleep(30 * time.millisecond)
	}
	shared_smoke_expect(manager.snapshot().pid == 0, 'shared Relay acceptance step 104 failed')!
	manager.start(project, binary)!
	wait_status_ready(mut manager)!
	shared_smoke_expect(manager.snapshot().config_status.state == .effective, 'shared Relay acceptance step 107 failed')!
	shared_smoke_expect(os.read_file(path)! == original, 'shared Relay acceptance step 108 failed')!
	// Check the project Agent: the Hub admin app may own a separate listener runtime.
	agent_base := base
	mut before := SharedProbeRuntime{}
	until := time.ticks() + 7000
	for time.ticks() < until {
		hub.tick()
		manager.tick()
		before = json.decode[SharedProbeRuntime](shared_smoke_call(agent_base, manager.snapshot().token, '/admin/runtime', .get, '')!.body)!
		if before.relay.agents.any(it.state == 'registered') { break }
		time.sleep(50 * time.millisecond)
	}
	shared_smoke_expect(before.relay.carriers.len == 1 && before.relay.agents.any(it.state == 'registered'), 'project agent did not connect')!
	shared_smoke_expect(host.probe_shared_relay(profile).ok, 'shared Relay acceptance step 118 failed')!
	after := json.decode[SharedProbeRuntime](shared_smoke_call(agent_base, manager.snapshot().token, '/admin/runtime', .get, '')!.body)!
	shared_smoke_expect(after.relay.carriers == before.relay.carriers && after.relay.agents.any(it.state == 'registered'), 'probe replaced live business connection')!
	manager.prepare_shared_relay_login(profile) or {
		println('PASS shared Relay: independent drafts → authorized Admin import → cross-include whole-project validation/publication → pending → restart → effective and connected; duplicate ID rejected; probe preserved live carrier')
		return
	}
	return error('duplicate project Relay ID accepted')
}

struct SharedProbeCarrier {
	relay_id   string
	carrier_id string
}

struct SharedProbeAgent {
	state string
}

struct SharedProbeRelay {
	agents   []SharedProbeAgent
	carriers []SharedProbeCarrier
}

struct SharedProbeRuntime {
	relay SharedProbeRelay
}

fn shared_smoke_expect(ok bool, message string) ! {
	if !ok { return error(message) }
}
