module devmcp

import host
import json2 as json
import net
import net.http
import os
import time

struct ToolEnvelope {
	result ToolAnswer
}

struct ToolAnswer {
	content  []ToolText
	is_error bool @[json: isError]
}

struct ToolText {
	text string
}

fn tool_value(body string) !string {
	envelope := json.decode[ToolEnvelope](body)!
	if envelope.result.is_error || envelope.result.content.len != 1 { return error(body) }
	return envelope.result.content[0].text
}

fn rpc(service &Service, body string, session string, authenticated bool, origin string, methods ...http.Method) !http.Response {
	method := if methods.len == 1 { methods[0] } else { http.Method.post }
	mut request := http.Request{ url: service.url, method: method, data: body, read_timeout: 10 * time.second }
	request.add_header(.content_type, 'application/json')
	request.add_header(.accept, 'application/json, text/event-stream')
	if authenticated { request.add_header(.authorization, 'Bearer ' + service.token) }
	if origin != '' { request.add_custom_header('Origin', origin)! }
	if session != '' {
		request.add_custom_header('MCP-Session-Id', session)!
		request.add_custom_header('MCP-Protocol-Version', '2025-11-25')!
	}
	return request.do()!
}

fn tool(service &Service, session string, name string, arguments string) !string {
	response := rpc(service, '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"${name}","arguments":${arguments}}}', session, true, '')!
	assert response.status_code == 200, response.body
	return response.body
}

fn listed_tools(service &Service, session string) !http.Response {
	mut rows := []json.Any{}
	mut cursor := ''
	mut seen := map[string]bool{}
	for {
		params := if cursor == '' {
			'{}'
		} else {
			json.encode({
				'cursor': cursor
			})
		}
		response := rpc(service, '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":${params}}', session, true, '')!
		assert response.status_code == 200, response.body
		result := json.decode[json.Any](response.body)!.as_map()['result'].as_map()
		rows << result['tools'].as_array()
		cursor = (result['nextCursor'] or { json.Any('') }).str()
		if cursor == '' { break }
		assert !seen[cursor], 'tools/list repeated cursor'
		seen[cursor] = true
	}
	return http.Response{
		status_code: 200
		body:        json.encode({
			'jsonrpc': json.Any('2.0')
			'id':      json.Any(2)
			'result':  json.Any({
				'tools': json.Any(rows)
			})
		})
	}
}

fn assert_capability_catalog(service &Service, session string, tools_body string, args string) ! {
	listed := json.decode[json.Any](tools_body)!.as_map()['result'].as_map()['tools'].as_array()
	catalog := json.decode[json.Any](tool_value(tool(service, session, 'capabilities_list', args)!)!)!.as_map()
	assert catalog['catalog_version'].int() == 1
	assert catalog['coverage_status'].str() == 'partial'
	assert catalog['coverage'].as_array().len > 0
	mut seen := map[string]bool{}
	mut available := []string{}
	for item in catalog['desktop'].as_array() {
		entry := item.as_map()
		id := entry['id'].str()
		assert id !in seen
		assert entry['domain'].str() != 'unclassified'
		seen[id] = true
		if entry['available'].bool() {
			available << id
		} else {
			assert entry['reason'].str() != ''
		}
	}
	mut actual := listed.map(it.as_map()['name'].str())
	available.sort()
	actual.sort()
	assert available == actual
	guide_tool := listed.filter(it.as_map()['name'].str() == 'guidance_get')[0].as_map()
	topics := guide_tool['inputSchema'].as_map()['properties'].as_map()['topic'].as_map()['enum'].as_array().map(it.str())
	for topic in ['workflow', 'pipeline', 'wechat-cloud-functions', 'codexbot', 'deploy', 'debug'] {
		assert topic in topics, topic
		mut arguments := json.decode[map[string]json.Any](args)!
		arguments['topic'] = json.Any(topic)
		guide := tool_value(tool(service, session, 'guidance_get', json.encode(arguments))!)!
		assert guide.contains('desktop_package') && guide.contains(if topic == 'workflow' {
			'"guidance_version":"2"'
		} else {
			'"guidance_version":"1"'
		}), topic
	}
}

fn test_official_mcp_over_http_authentication_workspace_worker_and_revocation() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'vhttpd-mcp-http-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir(root)!
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', root + '/private-data', true)
	defer {
		os.unsetenv('VHTTPD_DESKTOP_DATA_DIR')
		os.rmdir_all(root) or {}
	}
	worker := host.new_worker()
	defer {
		worker.commands <- host.Command{ action: .shutdown }
		_ := <-worker.done
	}
	mut service := start(worker, root, '/unused-runtime', 'test')!
	defer { service.close() }
	initialize := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"integration-test","version":"1"}}}'
	assert rpc(service, initialize, '', false, '')!.status_code == 401
	assert rpc(service, initialize, '', true, 'https://example.com')!.status_code == 403
	response := rpc(service, initialize, '', true, '')!
	assert response.status_code == 200, response.body
	session := response.header.get_custom('MCP-Session-Id') or { return error('missing session header') }
	assert session != ''
	initialized := rpc(service, '{"jsonrpc":"2.0","method":"notifications/initialized"}', session, true, '')!
	assert initialized.status_code == 202
	tools := listed_tools(service, session)!
	assert_capability_catalog(service, session, tools.body, '{}')!
	assert tools.body.contains('changes_prepare') && tools.body.contains('application_request')
	created := tool(service, session, 'project_create', '{"name":"hello","template":"vjsx-http"}')!
	assert !created.contains('"isError":true'), created
	assert os.is_file(root + '/hello/main.mjs')
	assert tool(service, session, 'runtime_diagnostics_get', '{"topic":"graph"}')!.contains('runtime_not_running')
	assert tool(service, session, 'runtime_diagnostics_get', '{"topic":"/admin/config"}')!.contains('"isError":true')
	pkg := tool_value(tool(service, session, 'runtime_package_get', '{}')!)!
	assert !pkg.contains('/unused-runtime')
	assert pkg.contains('"available":false')
	context := tool(service, session, 'context_get', '{}')!
	assert context.contains('hello'), context
	read := tool(service, session, 'files_read', '{"path":"vhttpd.toml"}')!
	project := host.project_from_file(root + '/hello/vhttpd.toml', '')!
	secret := host.inspect_project(project)!.config_token
	assert !read.contains(secret) && read.contains('vhttpd-secret-'), read
	source := json.decode[map[string]string](tool_value(tool(service, session, 'files_read', '{"path":"main.mjs"}')!)!)!
	prepared := tool_value(tool(service, session, 'changes_prepare', json.encode({
		'files': [source]
	}))!)!
	preview := json.decode[json.Any](prepared)!.as_map()
	id_args := json.encode({
		'id': preview['id'].str()
	})
	assert tool_value(tool(service, session, 'changes_validate', id_args)!)!.contains('true')
	assert tool_value(tool(service, session, 'changes_apply', id_args)!)!.contains('applied')
	assert tool_value(tool(service, session, 'changes_restore', id_args)!)!.contains('true')
	assert tool(service, session, 'files_read', '{"path":"../private-data/credentials.json"}')!.contains('"isError":true')
	// GUI retains its separate snapshot stream, including the selected project.
	mut selected := false
	deadline := time.ticks() + 3000
	for time.ticks() < deadline {
		select {
			snapshot := <-worker.snapshots {
				if snapshot.project == project.config_path {
					selected = true
					break
				}
			}
			100 * time.millisecond {
			}
		}
	}
	assert selected
	assert json.decode[json.Any](service.connection_config())!.str().contains(service.url)
	service.close()
	call := host.DevelopmentCall{ tool: 'project_create', arguments: '{"name":"disabled","template":"vjsx-http"}', root: root, access: service.access }
	worker.development <- call
	assert (<-call.reply).error
	assert !os.exists(root + '/disabled')
}

fn test_application_switch_keeps_connection_and_invalidates_previews() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'mcp-application-switch-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir(root)!
	previous := os.getenv_opt('VHTTPD_DESKTOP_DATA_DIR')
	os.setenv('VHTTPD_DESKTOP_DATA_DIR', root + '/data', true)
	defer {
		if value := previous {
			os.setenv('VHTTPD_DESKTOP_DATA_DIR', value, true)
		} else {
			os.unsetenv('VHTTPD_DESKTOP_DATA_DIR')
		}
		os.rmdir_all(root) or {}
	}
	project := host.create_project(host.CreateProjectOptions{ name: 'env', parent_dir: root, template: 'environment' })!
	mut installer := host.new_manager()
	installer.select_project(project)!
	for name in ['alpha', 'beta'] {
		source := host.create_application_source(name, 'vjsx-api', 0)!
		installer.preview_component(source, name)!
		installer.install_component(installer.snapshot().component_preview.id, '')!
	}
	worker := host.new_worker()
	defer {
		worker.commands <- host.Command{ action: .shutdown }
		_ := <-worker.done
	}
	apps := host.development_applications(project)!
	alpha := apps.filter(it.id == 'alpha')[0]
	if _ := start_application(worker, project, 'alpha', '/unused', 'test', root) {
		return error('binding accepted an unrelated directory')
	}
	binary := os.getenv_opt('VHTTPD_DESKTOP_RELAY_TEST_RUNTIME') or { '/unused' }
	mut service := start_managed_application(worker, project, 'alpha', binary, 'test', alpha.root)!
	defer { service.close() }
	url, token := service.url, service.token
	initialize := '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"switch-test","version":"1"}}}'
	response := rpc(service, initialize, '', true, '')!
	session := response.header.get_custom('MCP-Session-Id') or { return error('missing session') }
	rpc(service, '{"jsonrpc":"2.0","method":"notifications/initialized"}', session, true, '')!
	listed := listed_tools(service, session)!
	assert !listed.body.contains('"name":"project_create"')
	for name in ['relay_create_prepare', 'relay_create_apply', 'relay_status', 'relay_revoke',
		'targets_list', 'target_status', 'operation_get', 'application_release_prepare',
		'application_release_apply', 'application_release_rollback', 'runtime_upgrade_prepare',
		'runtime_upgrade_apply', 'runtime_upgrade_rollback', 'takeover_status', 'takeover_prepare',
		'takeover_start', 'takeover_release'] {
		assert listed.body.contains('"name":"${name}"')
	}
	context := tool_value(tool(service, session, 'context_get', '{}')!)!
	assert !context.contains(root)
	binding := json.decode[json.Any](context)!.as_map()['binding_revision'].int()
	assert binding > 0
	assert_capability_catalog(service, session, listed.body, '{}')!
	catalog := tool_value(tool(service, session, 'capabilities_list', '{"include_runtime":true}')!)!
	runtime := json.decode[json.Any](catalog)!.as_map()
	if os.is_executable(binary) {
		schema := runtime['runtime_schema'].as_map()
		assert schema['source'].str() == 'runtime_package', catalog
		assert schema['domains'].as_array().any(it.as_map()['id'].str() == 'engines')
	} else {
		assert runtime['runtime_error'].str().contains('runtime_schema_unavailable'), catalog
	}
	status := spawn tool(service, session, 'relay_status', '{"binding_revision":${binding}}')
	for _ in 0 .. 100 {
		if service.poll_relay_calls(worker, 'test', host.SharedRelay{}, '', fn (_ string) bool {
			return false
		}, ManagementTargets{}) {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert tool_value(status.wait()!)!.contains('inactive')
	assert tool(service, session, 'relay_status', '{"binding_revision":${binding},"upstream":"https://invalid.test"}')!.contains('unexpected_relay_argument')
	guidance := tool_value(tool(service, session, 'guidance_get', '{"topic":"project"}')!)!
	assert guidance.contains('main.mjs')
	if binary != '/unused' {
		assert tool_value(tool(service, session, 'runtime_status', '{}')!)!.contains('stopped')
		assert tool_value(tool(service, session, 'schema_get', '{"domain":"engines","kind":"vjsx"}')!)!.contains('runtime_package')
		assert tool_value(tool(service, session, 'guidance_get', '{"topic":"develop"}')!)!.contains('changes_restore')
		assert tool_value(tool(service, session, 'guidance_get', '{"topic":"vjsx"}')!)!.contains('ctx.queryParam')
		verify_managed_relay(mut service, worker, u64(binding))!
	}
	mut relay := service.issue_relay(worker, 'test', false)!
	assert relay.token != service.token && relay.url != service.url
	relay_response := rpc(relay, initialize, '', true, '')!
	relay_session := relay_response.header.get_custom('MCP-Session-Id') or { return error('missing Relay session') }
	assert rpc(relay, '{"jsonrpc":"2.0","method":"notifications/initialized"}', relay_session, true, '')!.status_code == 202
	relay_tools := listed_tools(relay, relay_session)!
	assert_capability_catalog(relay, relay_session, relay_tools.body, '{"binding_revision":${binding}}')!
	assert relay_tools.body.contains('files_read')
	assert !relay_tools.body.contains('changes_apply')
	assert !relay_tools.body.contains('relay_status')
	assert !relay_tools.body.contains('runtime_diagnostics_get')
	assert relay_tools.body.contains('runtime_package_get')
	assert !relay_tools.body.contains('relay_create')
	assert !relay_tools.body.contains('relay_revoke')
	assert !relay_tools.body.contains('targets_list')
	assert !relay_tools.body.contains('target_status')
	assert !relay_tools.body.contains('operation_get')
	assert !relay_tools.body.contains('application_release_')
	assert !relay_tools.body.contains('runtime_upgrade_')
	assert !relay_tools.body.contains('takeover_')
	assert tool(relay, relay_session, 'files_read', '{"path":"main.mjs"}')!.contains('"isError":true')
	assert tool_value(tool(relay, relay_session, 'files_read', '{"path":"main.mjs","binding_revision":${binding}}')!)!.contains('alpha')

	source := json.decode[map[string]string](tool_value(tool(service, session, 'files_read', '{"path":"main.mjs"}')!)!)!
	prepared := json.decode[json.Any](tool_value(tool(service, session, 'changes_prepare', json.encode({
		'files': [source]
	}))!)!)!.as_map()
	id := prepared['id'] or { return error('missing preview') }
	if binary != '/unused' {
		verify_relay_edit(mut service, worker, root, binary, initialize, binding, alpha.listeners[0])!
	}
	service.select_application(worker, project, 'beta', '/unused')!
	assert service.url == url && service.token == token
	assert relay.grant.is_revoked()
	assert service.relay_config() == ''
	assert tool(service, session, 'files_read', '{"path":"main.mjs","binding_revision":${binding}}')!.contains('binding_changed')
	assert tool_value(tool(service, session, 'files_read', '{"path":"main.mjs"}')!)!.contains('beta')
	assert tool(service, session, 'changes_apply', json.encode({
		'id': id.str()
	}))!.contains('"isError":true')
	assert tool(service, session, 'files_read', '{"path":"../alpha/main.mjs"}')!.contains('"isError":true')
}

fn relay_test_port() !int {
	mut socket := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { socket.close() or {} }
	return socket.addr()!.port()!
}

fn verify_relay_edit(mut service Service, worker host.Worker, root string, binary string, initialize string, binding int, listener string) ! {
	external_url := os.getenv('VHTTPD_DESKTOP_RELAY_TEST_URL')
	profile_path := os.getenv('VHTTPD_DESKTOP_RELAY_TEST_PROFILE')
	mut grant := if profile_path != '' {
		profile := json.decode[host.SharedRelay](os.read_file(profile_path)!)!
		service.publish_relay(worker, 'test', profile, external_url, true)!
		assert service.relay_config().contains(external_url)
		service.relay
	} else {
		service.issue_relay(worker, 'test', true)!
	}
	mut endpoint_url := external_url
	mut hub := os.new_process(binary)
	defer {
		if hub.pid > 0 {
			hub.signal_term()
			hub.wait()
		}
		hub.close()
	}
	mut agent_config := ''
	if external_url == '' {
		web_port := relay_test_port()!
		carrier_port := relay_test_port()!
		hub_config := $embed_file('../../examples/config/mcp-relay-public-v2.toml').to_string()
			.replace('19930', web_port.str()).replace('19931', carrier_port.str())
			.replace('/tmp/vhttpd_mcp_relay_public_v2', root + '/relay-hub')
		os.write_file(root + '/hub.toml', hub_config)!
		hub.set_args(['--config', root + '/hub.toml'])
		hub.run()
		endpoint_url = 'http://127.0.0.1:${web_port}/mcp'
		agent_config = $embed_file('../../examples/config/mcp-relay-local-upstream-v2.toml').to_string()
			.replace('19931', carrier_port.str())
	} else if profile_path == '' {
		agent_config = os.read_file(os.getenv('VHTTPD_DESKTOP_RELAY_TEST_AGENT_CONFIG'))!
	}
	mut agent := os.new_process(binary)
	defer {
		if agent.pid > 0 {
			agent.signal_term()
			agent.wait()
		}
		agent.close()
	}
	if profile_path == '' {
		agent_config = agent_config.replace('http://127.0.0.1:3001/mcp', grant.url)
			.replace('/tmp/vhttpd_mcp_relay_local_upstream_v2', root + '/relay-agent')
		os.write_file(root + '/agent.toml', agent_config)!
		agent.set_args(['--config', root + '/agent.toml', '--host', '127.0.0.1', '--port',
			relay_test_port()!.str()])
		agent.run()
	}
	if endpoint_url.starts_with('wss://') {
		token_file := root + '/relay-client-token'
		os.write_file(token_file, grant.token)!
		os.chmod(token_file, 0o600)!
		defer { os.rm(token_file) or {} }
		run_websocket_smoke(endpoint_url, token_file, listener, 'edit')!
		service.revoke_relay()
		run_websocket_smoke(endpoint_url, token_file, listener, 'revoked')!
		return
	}
	endpoint := &Service{ url: endpoint_url, token: grant.token }
	mut session := ''
	mut last_response := ''
	for _ in 0 .. 30 {
		response := rpc(endpoint, initialize, '', true, '') or {
			time.sleep(150 * time.millisecond)
			continue
		}
		last_response = '${response.status_code}: ${response.body}'
		if response.status_code == 200 {
			session = response.header.get_custom('MCP-Session-Id') or { '' }
			break
		}
		time.sleep(150 * time.millisecond)
	}
	if session == '' { return error('Relay did not return an MCP session: ' + last_response) }
	probe_state, probe_code := probe_relay_handshake(endpoint_url, grant.token)
	assert probe_state == 'ready' && probe_code == 200
	assert rpc(endpoint, initialize, '', false, '')!.status_code == 401
	assert rpc(endpoint, '{"jsonrpc":"2.0","method":"notifications/initialized"}', session, true, '')!.status_code == 202
	assert rpc(endpoint, '', session, true, '', .get)!.status_code == rpc(grant, '', session, true, '', .get)!.status_code
	bound := '{"binding_revision":${binding}}'
	mut source := json.decode[map[string]string](tool_value(tool(endpoint, session, 'files_read', '{"path":"main.mjs","binding_revision":${binding}}')!)!)!
	source['content'] = 'export default ctx => ctx.json({message:"relay-verified"},200)'
	files := json.encode([source])
	preview := json.decode[json.Any](tool_value(tool(endpoint, session, 'changes_prepare', '{"files":${files},"binding_revision":${binding}}')!)!)!.as_map()
	id := preview['id'].str()
	change := '{"id":"${id}","binding_revision":${binding}}'
	assert tool_value(tool(endpoint, session, 'changes_validate', change)!)!.contains('true')
	assert tool_value(tool(endpoint, session, 'changes_apply', change)!)!.contains('applied')
	start := tool_value(tool(endpoint, session, 'runtime_start', bound)!)!
	assert start.contains('"accepted":true') && start.contains('"phase":"starting"')
	deadline := time.ticks() + 100000
	for {
		status := json.decode[map[string]string](tool_value(tool(endpoint, session, 'runtime_status', bound)!)!)!
		if status['readiness'] == 'ready' { break }
		assert status['phase'] in ['starting', 'running'], status.str()
		assert time.ticks() < deadline, status.str()
		time.sleep(500 * time.millisecond)
	}
	response := tool_value(tool(endpoint, session, 'application_request', '{"listener":"${listener}","path":"/api/hello","binding_revision":${binding}}')!)!
	assert response.contains('relay-verified')
	assert tool_value(tool(endpoint, session, 'runtime_stop', bound)!)!.contains('stopped')
	assert tool_value(tool(endpoint, session, 'changes_restore', change)!)!.contains('true')
	baseline := tool_value(tool(endpoint, session, 'files_read', '{"path":"main.mjs","binding_revision":${binding}}')!)!
	assert baseline.contains('alpha') && !baseline.contains('relay-verified')
	assert rpc(endpoint, '', session, true, '', .delete)!.status_code in [200, 204]
	service.revoke_relay()
	assert isnil(service.relay_agent) && service.relay_agent_dir == ''
	revoked := rpc(endpoint, initialize, '', true, '')!
	assert revoked.status_code != 200
}

fn run_websocket_smoke(url string, token_file string, listener string, phase string) ! {
	script := os.getenv('VHTTPD_DESKTOP_RELAY_TEST_WS_CLIENT')
	if script == '' { return error('set VHTTPD_DESKTOP_RELAY_TEST_WS_CLIENT to smoke.py') }
	mut process := os.new_process(os.find_abs_path_of_executable('python3')!)
	process.set_args([script, url, token_file, listener, phase])
	process.run()
	process.wait()
	process.close()
	if process.code != 0 { return error('WebSocket MCP smoke failed: ' + phase) }
}

fn verify_managed_relay(mut service Service, worker host.Worker, binding u64) ! {
	target := host.SharedRelay{ id: 'ab'.repeat(12), relay_id: 'desktop-mcp', name: 'Test Hub', url: 'wss://localhost/vhttpd/relay/desktop-mcp', token: 'test-carrier-secret' }
	url := 'https://localhost/mcp'
	deadline := time.now().unix() + 60
	approve := fn (_ string) bool { return true }
	deny := fn (_ string) bool { return false }
	prepare := RelayCall{ tool: 'relay_create_prepare', args: RelayArgs{ binding_revision: binding, target_id: target.id, mode: 'read_only' }, deadline: deadline }
	preview := service.manage_relay(worker, 'test', target, url, deny, prepare)!
	assert !preview.contains(target.token)
	mut apply := RelayCall{ tool: 'relay_create_apply', args: RelayArgs{ binding_revision: binding, plan_id: service.relay_plan.id }, deadline: deadline }
	if _ := service.manage_relay(worker, 'test', target, url, deny, apply) {
		return error('publication did not require Desktop approval')
	}
	assert service.relay_config() == ''
	_ = service.manage_relay(worker, 'test', target, url, deny, prepare)!
	apply = RelayCall{ ...apply, args: RelayArgs{ ...apply.args, plan_id: service.relay_plan.id } }
	if _ := service.manage_relay(worker, 'test', target, url + '/changed', approve, apply) {
		return error('changed Relay endpoint did not invalidate plan')
	}
	result := service.manage_relay(worker, 'test', target, url, approve, apply)!
	assert result.contains('agent_started')
	assert !result.contains(service.relay.token)
	assert !result.contains(target.token)
	token := service.relay.token
	assert service.manage_relay(worker, 'test', target, url, deny, apply)! == result
	assert service.relay.token == token
	old := service.relay
	revoke := RelayCall{ tool: 'relay_revoke', args: RelayArgs{ binding_revision: binding, publication_id: service.relay_publication_id }, deadline: deadline }
	if _ := service.manage_relay(worker, 'test', target, url, deny, RelayCall{ ...revoke, args: RelayArgs{ ...revoke.args, publication_id: 'stale' } }) {
		return error('stale publication ID revoked the active Relay')
	}
	assert service.manage_relay(worker, 'test', target, url, deny, revoke)!.contains('inactive')
	assert service.manage_relay(worker, 'test', target, url, deny, revoke)!.contains('inactive')
	assert old.grant.is_revoked()
	assert service.relay_config() == ''
}
