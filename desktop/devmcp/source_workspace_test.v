module devmcp

import host
import json2 as json
import net.http
import os
import time

fn source_rpc(service &Service, body string, session string) !http.Response {
	mut request := http.Request{ url: service.url, method: .post, data: body, read_timeout: 10 * time.second }
	request.add_header(.authorization, 'Bearer ' + service.token)
	request.add_header(.content_type, 'application/json')
	request.add_header(.accept, 'application/json, text/event-stream')
	if session != '' {
		request.add_custom_header('Mcp-Session-Id', session)!
		request.add_custom_header('MCP-Protocol-Version', '2025-11-25')!
	}
	return request.do()!
}

fn source_tool(service &Service, session string, name string, args string) !json.Any {
	response := source_rpc(service, '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"' + name + '","arguments":' + args + '}}', session)!
	value := json.decode[json.Any](response.body)!.as_map()
	r := value['result'] or { return error('protocol tool error') }
	if (r.as_map()['isError'] or { json.Any(false) }).bool() { return error(json.encode(r)) }
	return json.decode[json.Any](r.as_map()['content']!.as_array()[0].as_map()['text']!.str())!
}

fn source_session(service &Service) !string {
	response := source_rpc(service, '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"qa","version":"1"}}}', '')!
	session := response.header.get_custom('Mcp-Session-Id') or { return error('missing session id') }
	source_rpc(service, '{"jsonrpc":"2.0","method":"notifications/initialized"}', session)!
	return session
}

fn test_source_endpoint_initializes_binds_and_edits_an_uninstalled_project() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'source-mcp-${time.sys_mono_now()}')
	os.mkdir(root)!
	defer { os.rmdir_all(root) or {} }
	os.mkdir(root + '/empty')!
	worker := host.new_worker()
	defer {
		worker.commands <- host.Command{ action: .shutdown }
		_ := <-worker.done
	}
	mut service := start_source_workspace(worker, root, '/unused', 'qa')!
	defer { service.close() }
	session := source_session(service)!
	tools := source_rpc(service, '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}', session)!
	assert tools.status_code == 200, tools.body
	assert tools.body.contains('source_workspace_bind') && !tools.body.contains('application_install_apply'), tools.body
	assert !tools.body.contains('target_protocol_probe')
	context := source_tool(service, session, 'context_get', '{}')!
	assert context.as_map()['mode']!.str() == 'source_workspace'
	plan := source_tool(service, session, 'source_workspace_prepare', '{"binding_revision":1,"directory":"empty","template":"vjsx-http"}')!
	args := '{"binding_revision":1,"id":' + json.encode(plan.as_map()['plan_id']!) + '}'
	bound := source_tool(service, session, 'source_workspace_bind', args)!
	assert bound.as_map()['binding_revision']!.int() == 2
	assert !os.exists(root + '/empty/app.json')
	files := source_tool(service, session, 'files_list', '{"binding_revision":2}')!
	assert json.encode(files).contains('main.mjs') && json.encode(files).contains('AGENTS.md')
	if _ := source_tool(service, session, 'files_read', '{"binding_revision":1,"path":"main.mjs"}') {
		return error('old source binding accepted')
	}
	mut relay := service.issue_relay(worker, 'qa', true)!
	defer { relay.close() }
	relay_session := source_session(relay)!
	assert (source_tool(relay, relay_session, 'files_read', '{"binding_revision":2,"path":"main.mjs"}')!).as_map()['content']!.str() != ''
	if _ := source_tool(relay, relay_session, 'source_workspace_prepare', '{"binding_revision":2,"directory":"."}') {
		return error('public directory rebinding exposed')
	}
	source_tool(service, session, 'source_workspace_unbind', '{"binding_revision":2}')!
	if _ := source_tool(relay, relay_session, 'context_get', '{}') {
		return error('old Relay followed new source binding')
	}
	scope := RelayScope{ source_workspace: true, grant: host.new_development_grant(0), writable: true }
	for spec in source_workspace_tool_specs() {
		assert !development_tool_available(spec, true, scope)
	}
}
