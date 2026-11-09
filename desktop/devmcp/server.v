module devmcp

import crypto.rand
import crypto.subtle
import host
import json2 as json
import mcp
import net
import net.http
import os
import time

@[heap]
pub struct Service {
pub:
	url   string
	root  string
	token string
mut:
	relay_calls          chan RelayCall
	relay_plan           RelayPlan
	remote_hub           host.McpHubTarget
	remote_hub_id        string
	remote_hub_ports     host.McpHubPorts
	server               &http.Server = unsafe { nil }
	relay                &Service     = unsafe { nil }
	relay_agent          &os.Process  = unsafe { nil }
	relay_agent_dir      string
	relay_public_url     string
	relay_publication_id string
	relay_target_id      string
	relay_mode           string
	relay_expires        i64
	grant                &host.DevelopmentAccess = unsafe { nil }
	access               &host.DevelopmentAccess = &host.DevelopmentAccess{}
}

struct Gateway {
	token    string
	grant    &host.DevelopmentAccess = unsafe { nil }
	protocol &mcp.Server
}

fn (mut h Gateway) handle(request http.Request) http.Response {
	if !isnil(h.grant) && h.grant.is_revoked() {
		return http.Response{ status_code: 410, body: 'MCP grant expired or revoked' }
	}
	if request.url.all_before('?') != '/mcp' {
		return http.Response{ status_code: 404, body: 'Not found' }
	}
	if subtle.constant_time_compare((request.header.get(.authorization) or { '' }).bytes(), ('Bearer ' + h.token).bytes()) != 1 {
		return http.Response{ status_code: 401, body: 'Unauthorized' }
	}
	// Desktop has no browser-based MCP client. Never accept website origins,
	// including `null`; command-line/native MCP clients omit Origin.
	if request.header.get_custom('Origin') or { '' } != '' {
		return http.Response{ status_code: 403, body: 'Origin forbidden' }
	}
	if request.data.len > 8 * 1024 * 1024 {
		return http.Response{ status_code: 413, body: 'Request too large' }
	}
	response := h.protocol.handle_http_request(request)
	return h.complete_tool_catalog(request, response)
}

pub fn start(worker host.Worker, root string, binary string, version string) !&Service {
	return start_service(worker, root, binary, version, &host.DevelopmentAccess{})!
}

pub fn start_workspace(worker host.Worker, project host.Project, binary string, version string) !&Service {
	access := &host.DevelopmentAccess{}
	call := host.DevelopmentCall{
		tool:      'project_select'
		root:      project.workdir
		arguments: json.encode({
			'path': os.path_rel(project.workdir, project.config_path)!.replace('\\', '/')
		})
		access:    access
	}
	worker.development <- call
	result := <-call.reply
	if result.error { return error(result.value) }
	return start_service(worker, project.workdir, binary, version, access)!
}

pub fn start_source_workspace(worker host.Worker, directory string, binary string, version string) !&Service {
	access := &host.DevelopmentAccess{}
	call := host.DevelopmentCall{ tool: '_open_source_workspace', arguments: '{}', directory: directory, binary: binary, access: access }
	worker.development <- call
	result := <-call.reply
	if result.error { return error(result.value) }
	return start_service(worker, directory, binary, version, access, RelayScope{ source_workspace: true })!
}

pub fn start_application(worker host.Worker, project host.Project, application string, binary string, version string, directory ...string) !&Service {
	return start_application_service(worker, project, application, binary, version, chan RelayCall{}, directory)!
}

pub fn start_managed_application(worker host.Worker, project host.Project, application string, binary string, version string, directory string) !&Service {
	return start_application_service(worker, project, application, binary, version, chan RelayCall{cap: 1}, [directory])!
}

fn start_application_service(worker host.Worker, project host.Project, application string, binary string, version string, calls chan RelayCall, directory []string) !&Service {
	access := &host.DevelopmentAccess{}
	call := host.DevelopmentCall{
		tool:        '_select_application'
		arguments:   '{}'
		project:     project
		application: application
		directory:   if directory.len > 0 {
			directory[0]
		} else {
			''
		}
		binary:      binary
		access:      access
	}
	worker.development <- call
	result := <-call.reply
	if result.error { return error(result.value) }
	return start_service(worker, project.workdir, binary, version, access, RelayScope{ calls: calls })!
}

struct RelayScope {
	source_workspace bool
	calls            chan RelayCall
	grant            &host.DevelopmentAccess = unsafe { nil }
	generation       u64
	writable         bool
}

fn start_service(worker host.Worker, root string, binary string, version string, access &host.DevelopmentAccess, scopes ...RelayScope) !&Service {
	scope := if scopes.len == 1 { scopes[0] } else { RelayScope{} }
	if !os.is_dir(root) || os.is_link(root) { return error('请选择存在的开发目录。') }
	canonical := os.real_path(root)
	token := rand.bytes(32)!.hex()
	mut protocol := mcp.new_server(
		name:         'vhttpd-desktop'
		version:      version
		instructions: 'Local vhttpd development. Call context_get, templates_list, then files_read. Keep secret placeholders unchanged. Prepare and validate changes before stopping the shared runtime and applying. Start and verify business requests; restore on failure. All tools operate within the Desktop-selected workspace.'
	)
	register_tools(mut protocol, worker, canonical, binary, access, scope, version)!
	if management_tools_available(scope) {
		register_relay_tools(mut protocol, scope.calls)!
	}
	listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	address := listener.addr()!.str()
	mut server := &http.Server{ addr: address, listener: listener, handler: Gateway{ token: token, protocol: &protocol, grant: scope.grant }, show_startup_message: false, accept_timeout: 100 * time.millisecond, write_timeout: 120 * time.second, worker_num: 4 }
	service := &Service{ url: 'http://${address}/mcp', root: canonical, token: token, relay_calls: scope.calls, server: server, access: access, grant: scope.grant }
	spawn server.listen_and_serve()
	server.wait_till_running() or {
		server.close()
		return err
	}
	return service
}

pub fn (mut s Service) select_application(worker host.Worker, project host.Project, application string, binary string, directory ...string) ! {
	if s.access.selection().application.id == '' {
		return error('close_workspace_session_before_binding')
	}
	call := host.DevelopmentCall{
		tool:        '_select_application'
		arguments:   '{}'
		project:     project
		application: application
		directory:   if directory.len > 0 {
			directory[0]
		} else {
			''
		}
		binary:      binary
		access:      s.access
	}
	worker.development <- call
	result := <-call.reply
	if result.error { return error(result.value) }
	s.revoke_relay()
}

// The relay upstream must target this dedicated loopback listener, with the
// client bearer forwarded by the relay. The primary Desktop token stays local.
pub fn (mut s Service) issue_relay(worker host.Worker, version string, writable bool) !&Service {
	selection := s.access.selection()
	if s.access.is_revoked() || selection.application.id == '' {
		return error('bind a local application before issuing a Relay grant')
	}
	s.revoke_relay()
	expires := time.now().unix() + 3600
	scope := RelayScope{
		grant:            host.new_development_grant(expires)
		generation:       selection.generation
		writable:         writable
		source_workspace: selection.source_workspace
	}
	s.relay = start_service(worker, selection.project.workdir, selection.binary, version, s.access, scope)!
	s.relay_expires = expires
	return s.relay
}

pub fn (mut s Service) revoke_relay() {
	s.relay_plan = RelayPlan{}
	if !isnil(s.relay) {
		s.relay.close()
		s.relay = unsafe { nil }
	}
	if !isnil(s.relay_agent) {
		s.relay_agent.signal_kill()
		s.relay_agent.wait()
		s.relay_agent.close()
		s.relay_agent = unsafe { nil }
	}
	if s.relay_agent_dir != '' {
		os.rmdir_all(s.relay_agent_dir) or {}
		s.relay_agent_dir = ''
	}
	s.relay_public_url = ''
	s.relay_publication_id = ''
	s.relay_target_id = ''
	s.relay_mode = ''
	s.relay_expires = 0
	s.reclaim_remote_hub()
}

pub fn (s &Service) relay_cleanup_pending() bool {
	return s.remote_hub_id != '' && s.relay_public_url == ''
}

fn (mut s Service) reclaim_remote_hub() {
	if s.remote_hub_id == '' { return }
	s.remote_hub.request(s.remote_hub_id, '', true) or { return }
	s.remote_hub_id = ''
	s.remote_hub_ports = host.McpHubPorts{}
}

pub fn (s &Service) relay_config() string {
	return if isnil(s.relay) { '' } else { s.relay.connection_config_for(s.relay_public_url) }
}

pub fn (s &Service) selection() host.DevelopmentSelection { return s.access.selection() }

pub fn (mut s Service) close() {
	s.revoke_relay()
	if !isnil(s.server) {
		if isnil(s.grant) {
			s.access.revoke()
		} else {
			s.grant.revoke()
		}
		s.server.close()
		s.server = unsafe { nil }
	}
}

// Credentials are only shown on explicit connection-info UI; never persisted.
pub fn (s &Service) connection_config() string {
	return s.connection_config_for(s.url)
}

fn (s &Service) connection_config_for(public_url string) string {
	return json.encode({
		'mcpServers': {
			'vhttpd-desktop': Connection{
				url:     if public_url == '' { s.url } else { public_url }
				headers: {
					'Authorization': 'Bearer ' + s.token
				}
			}
		}
	},
		prettify: true
	)
}

struct Connection {
	url     string
	headers map[string]string
}

struct ToolSpec {
	name        string
	description string
	properties  string = '{}'
	required    string = '[]'
	read_only   bool
}

fn development_tool_specs() []ToolSpec {
	mut specs := source_workspace_tool_specs()
	specs << [
		ToolSpec{ name: 'capabilities_list', description: 'List Desktop tool capabilities and session availability. Set include_runtime to include the selected vhttpd runtime schema. Use guidance_get for workflows.', properties: '{"include_runtime":{"type":"boolean"}}', read_only: true },
		ToolSpec{ name: 'context_get', description: 'Get selected project, vjsx script guidance and required development workflow.', read_only: true },
		ToolSpec{ name: 'guidance_get', description: 'Read project guidance, selected runtime APIs or Desktop-packaged workflow, project profiles, deployment and debugging Skills. The response identifies its source and version.', properties: '{"topic":{"type":"string","enum":["project","develop","vjsx","workflow","pipeline","wechat-cloud-functions","codexbot","deploy","debug"]}}', required: '["topic"]', read_only: true },
		ToolSpec{ name: 'schema_get', description: 'Read schema from the live runtime or the selected runtime package while stopped. Omit domain and kind for discovery.', properties: '{"domain":{"type":"string"},"kind":{"type":"string"}}', read_only: true },
		ToolSpec{ name: 'templates_list', description: 'List embedded runnable vhttpd templates and their source/configuration.', read_only: true },
		ToolSpec{ name: 'application_templates_list', description: 'List standalone application component templates and their runtime probes.', read_only: true },
		ToolSpec{ name: 'application_install_prepare', description: 'Preflight local installation in the selected stopped environment. Pass either a template or a workspace-relative app.json or component TOML path with existing application identity.', properties: '{"name":{"type":"string"},"template":{"type":"string"},"path":{"type":"string"},"component_port":{"type":"integer","minimum":0,"maximum":65535}}', required: '["name"]' },
		ToolSpec{ name: 'application_install_apply', description: 'Install the exact preflighted component in the stopped local environment. Select the installed application in Desktop to enable app-bound development and remote release.', properties: '{"id":{"type":"string"}}', required: '["id"]' },
		ToolSpec{ name: 'project_create', description: 'Create and select a new local project under the authorized workspace. Existing directories are never overwritten.', properties: '{"name":{"type":"string"},"template":{"type":"string","enum":["vjsx-http","vjsx-api","environment"]}}', required: '["name","template"]' },
		ToolSpec{ name: 'project_select', description: 'Select an existing project by workspace-relative TOML path. Stop the current runtime first.', properties: '{"path":{"type":"string"}}', required: '["path"]' },
		ToolSpec{ name: 'files_list', description: 'List editable text files and their revisions in the selected project. Private/runtime files are excluded.', read_only: true },
		ToolSpec{ name: 'files_read', description: 'Read a project-relative text file and revision. Preserve secret placeholders in edits.', properties: '{"path":{"type":"string"}}', required: '["path"]', read_only: true },
		ToolSpec{ name: 'changes_prepare', description: 'Prepare up to 32 text-file replacements/additions and return a diff. Pass the files_read revision; use empty revision only for a new file.', properties: '{"files":{"type":"array","minItems":1,"maxItems":32,"items":{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string"},"content":{"type":"string"},"revision":{"type":"string"}},"required":["path","content","revision"]}}}', required: '["files"]' },
		ToolSpec{ name: 'changes_validate', description: 'Compile the entire configuration including include changes; source code must also pass runtime startup and request checks.', properties: '{"id":{"type":"string"}}', required: '["id"]', read_only: true },
		ToolSpec{ name: 'changes_apply', description: 'Revalidate and apply a prepared change set while the runtime is stopped. File changes since preview cause rejection. No crash recovery; restore is available in this Desktop session.', properties: '{"id":{"type":"string"}}', required: '["id"]' },
		ToolSpec{ name: 'changes_restore', description: 'Restore an applied change set while stopped. Rejects files changed externally since apply.', properties: '{"id":{"type":"string"}}', required: '["id"]' },
		ToolSpec{ name: 'changes_discard', description: 'Discard a preview or release its in-memory recovery record after verification. Does not change project files; discarded recovery records cannot be restored.', properties: '{"id":{"type":"string"}}', required: '["id"]' },
		ToolSpec{ name: 'runtime_package_get', description: 'Inspect the selected local vhttpd package version, source and availability without exposing its filesystem path.', read_only: true },
		ToolSpec{ name: 'runtime_packages_list', description: 'List installed local package IDs and the selected package without exposing filesystem paths. Probe a package before choosing it in Desktop.', read_only: true },
		ToolSpec{ name: 'runtime_releases_list', description: 'Discover official complete runtime releases and checksums for a target platform. Accepts an optional official version tag and stable, development or all channel. Local Desktop session required.', properties: '{"platform":{"type":"string","enum":["macos-arm64","linux-amd64","linux-arm64"]},"channel":{"type":"string","enum":["all","stable","development"]},"tag":{"type":"string"}}', read_only: true },
		ToolSpec{ name: 'runtime_package_probe', description: 'Check a local installed package ID against the entire bound environment configuration without switching packages. Use runtime_packages_list to discover IDs. Startup and business verification are still required after selecting the package in Desktop.', properties: '{"package_id":{"type":"string"}}', required: '["package_id"]', read_only: true },
		ToolSpec{ name: 'runtime_diagnostics_get', description: 'Read a bounded local environment diagnostic snapshot from the running runtime. Topics: graph, workers, providers, relay, websocket. Available to local Desktop sessions.', properties: '{"topic":{"type":"string","enum":["graph","workers","providers","relay","websocket"]}}', required: '["topic"]', read_only: true },
		ToolSpec{ name: 'runtime_status', description: 'Get runtime phase, PID and configuration status without credentials. After a Relay start or restart, poll until readiness is ready, then verify with application_request. Stop polling if phase is failed or stopped.', read_only: true },
		ToolSpec{ name: 'runtime_start', description: 'Start the selected local runtime. Over Relay, returns acceptance before warmup completes; check runtime_status and then verify with application_request. Direct calls wait for readiness.' },
		ToolSpec{ name: 'runtime_stop', description: 'Stop the shared local process and wait. This affects every application in that environment; never force-kills an external process.' },
		ToolSpec{ name: 'runtime_restart', description: 'Stop and start the selected runtime, affecting every application in it. Over Relay, check runtime_status after acceptance. Direct calls wait for readiness.' },
		ToolSpec{ name: 'logs_query', description: 'Read up to 200 recent runtime log lines, with optional substring filter. Known credentials are redacted.', properties: '{"search":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":200}}', read_only: true },
		ToolSpec{ name: 'application_probe_options_get', description: 'Discover bound business probe listener IDs, IPv4/IPv6 family, TLS and dedicated auth_ref IDs from configuration without connecting or disclosing credentials/certificate paths. Configuration is not live readiness.', read_only: true },
		ToolSpec{ name: 'application_protocol_probe', description: 'Bounded stream/SSE, WebSocket text, or business MCP Streamable HTTP initialize/tools-list probe of a configured IPv4/IPv6 loopback business listener. WebSocket message may modify application state; requires write authorization. Optional auth_ref selects the routed adapter options.probe_bearer_token privately. TLS always validates chain and name; tls_trust=listener_certificate explicitly trusts the configured public certificate. No raw credentials, arbitrary URLs/headers, redirects or MCP tools/call. Closes transport and attempts MCP session deletion. Timeout and samples are bounded.', properties: protocol_probe_properties(), required: '["listener","path","protocol"]' },
		ToolSpec{ name: 'application_request', description: 'Send a JSON HTTP request to a configured local business listener. Never follows redirects or calls Admin. POST/PUT/PATCH/DELETE can modify application data.', properties: '{"listener":{"type":"string"},"path":{"type":"string"},"method":{"type":"string","enum":["GET","POST","PUT","PATCH","DELETE","HEAD","OPTIONS"]},"body":{"type":"string"}}', required: '["listener","path"]' },
	]
	return specs
}

fn register_tools(mut server mcp.Server, worker host.Worker, root string, binary string, access &host.DevelopmentAccess, scope RelayScope, version string) ! {
	specs := development_tool_specs()
	bound_application := access.selection().application.id != ''
	for spec in specs {
		if !development_tool_available(spec, bound_application, scope) { continue }
		name := spec.name
		mut properties := json.decode[map[string]json.Any](spec.properties)!
		if name != 'context_get' {
			properties['binding_revision'] = json.Any({
				'type':    json.Any('integer')
				'minimum': json.Any(1)
			})
		}
		mut required := json.decode[[]string](spec.required)!
		if (!isnil(scope.grant) || scope.source_workspace) && name != 'context_get' {
			required << 'binding_revision'
		}
		property_schema := json.encode(properties)
		required_schema := json.encode(required)
		server.add_tool(mcp.Tool{ name: name, description: spec.description, input_schema: '{"type":"object","additionalProperties":false,"properties":${property_schema},"required":${required_schema}}', annotations: mcp.ToolAnnotations{ read_only_hint: spec.read_only, destructive_hint: !spec.read_only, open_world_hint: false } }, fn [worker, root, binary, name, access, scope, bound_application, version, property_schema] (ctx mcp.Context, arguments string) !mcp.ToolResult {
			if ctx.is_cancelled() {
				return mcp.ToolResult{ is_error: true, content: '[${mcp.text_content('cancelled')}]' }
			}
			if access.is_revoked() || (!isnil(scope.grant) && scope.grant.is_revoked()) {
				return error('MCP service disabled')
			}
			if name.starts_with('source_workspace_') {
				expected := json.decode[map[string]json.Any](property_schema)!
				for key, _ in json.decode[map[string]json.Any](arguments)! {
					if key !in expected { return error('unexpected_source_workspace_argument') }
				}
			}
			if name == 'application_protocol_probe' {
				for key, _ in json.decode[map[string]json.Any](arguments)! {
					if key !in ['binding_revision', 'protocol', 'listener', 'path', 'message',
						'timeout_ms', 'max_items', 'auth_ref', 'tls_trust', 'tls_server_name'] {
						return error('unexpected_protocol_probe_argument')
					}
				}
			}
			selection := access.selection()
			// Tool registration is fixed for the lifetime of this endpoint.
			if name == 'capabilities_list' {
				args := json.decode[CapabilityArgs](arguments)!
				if !args.include_runtime {
					return capability_result(scope, bound_application, host.DevelopmentReply{})
				}
			}
			call := host.DevelopmentCall{
				tool:            if name == 'capabilities_list' { 'schema_get' } else { name }
				arguments:       if name == 'capabilities_list' {
					capability_schema_arguments(arguments)!
				} else {
					arguments
				}
				root:            if selection.application.id != '' {
					selection.project.workdir
				} else {
					root
				}
				binary:          if selection.application.id != '' {
					selection.binary
				} else {
					binary
				}
				access:          access
				grant:           scope.grant
				desktop_version: version
				generation:      if isnil(scope.grant) {
					selection.generation
				} else {
					scope.generation
				}
			}
			select {
				worker.development <- call {
				}
				else {
					return error('Desktop busy; retry after current operation')
				}
			}
			result := <-call.reply
			if name == 'capabilities_list' {
				return capability_result(scope, bound_application, result)
			}
			return mcp.ToolResult{ is_error: result.error, content: '[${mcp.text_content(result.value)}]' }
		})!
	}
}
