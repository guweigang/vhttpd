module devmcp

import crypto.rand
import host
import json2 as json
import mcp
import net.urllib
import os
import time

struct RelayCall {
	tool     string
	args     RelayArgs
	deadline i64
	reply    chan host.DevelopmentReply = chan host.DevelopmentReply{cap: 1}
}

struct RelayArgs {
	binding_revision u64
	pipeline string
	paths []string
	target_id        string
	mode             string
	plan_id          string
	publication_id   string
	operation_id     string
	component string
	installation_id string
	rollback_from string
	target_runtime_id string
	auth_app_id string
	account string
	lease_id string
	topic string
	application_id string
	search string
	limit int = 100
	cursor u64
	host_id string
	listener string
	path string
	method string = 'GET'
	protocol string
	message string
	timeout_ms int = 3000
	auth_ref string
	tls_trust string = 'system'
	tls_server_name string
	max_items int = 4
	verify_path string
	connection_id string
	source_connection_id string
	hub_target_id string
	relay_id string
	adapter_id string
	resource_id string
	updates map[string]json.Any
	edits []host.McpConfigEdit
	version_id string
	remove_fields []string
	route string
	action string
	port int
	tag string
	platform string
	download_id string
	package_id string
	ssh_host string
	ssh_user string
	ssh_port int = 22
	credential_host_id string
	name string
	template string = 'environment'
	runtime_id string
	web_port int
	admin_port int
}

struct RelayPlan {
	id         string
	target     host.SharedRelay
	remote     host.McpHubTarget
	url        string
	mode       string
	generation u64
	expires    i64
	applied    bool
}

fn management_tool_specs() []ToolSpec {
	revision := '"binding_revision":{"type":"integer","minimum":1}'
	probe_properties := protocol_probe_properties()
	mut specs := lifecycle_tool_specs(revision)
	specs << package_tool_specs(revision)
	specs << ordinary_relay_tool_specs(revision)
	specs << [
		ToolSpec{ name: 'target_probe_options_get', description: 'Discover configuration-selected business probe listeners, IPv4/IPv6 family, TLS and dedicated auth_ref IDs on a connected registered target. No sockets or credentials; not a readiness check.', properties: revision + ',"target_id":{"type":"string"}', required: '"binding_revision","target_id"', read_only: true },
		ToolSpec{ name: 'target_protocol_probe', description: 'After Desktop confirmation, probe stream/SSE, WebSocket text or business MCP initialize/tools-list on a registered target configuration-selected IPv4/IPv6 loopback business listener. Message may affect application state. Bounded time/samples; auth_ref selects a routed adapter literal probe_bearer_token (remote environment references are rejected rather than resolved on Desktop); TLS chain/name validation is mandatory (system or explicit listener_certificate trust). No raw credentials, custom URLs/headers, redirects or tools/call.', properties: revision + ',"target_id":{"type":"string"},' + probe_properties[1..probe_properties.len - 1], required: '"binding_revision","target_id","listener","path","protocol"' },
		ToolSpec{ name: 'target_request', description: 'Verify a registered target business HTTP listener using GET or HEAD. Listener IDs come from target_applications_list. Never follows redirects or sends Admin requests. Returns status and a bounded response with known credentials masked.', properties: revision + ',"target_id":{"type":"string"},"listener":{"type":"string"},"path":{"type":"string"},"method":{"type":"string","enum":["GET","HEAD"]}', required: '"binding_revision","target_id","listener","path"', read_only: true },
		ToolSpec{ name: 'host_inventory_get', description: 'Read a registered host connection state, discovered environments and installed runtime packages. Distinguishes Desktop-registered targets from discovered candidates without exposing paths or credentials.', properties: revision + ',"host_id":{"type":"string"}', required: '"binding_revision","host_id"', read_only: true },
		ToolSpec{ name: 'target_diagnostics_get', description: 'Read live graph, worker, provider, Relay or process-wide WebSocket diagnostics from a connected registered environment. Only fixed diagnostic endpoints and bounded safe fields are exposed.', properties: revision + ',"target_id":{"type":"string"},"topic":{"type":"string","enum":["graph","workers","providers","relay","websocket"]}', required: '"binding_revision","target_id","topic"', read_only: true },
		ToolSpec{ name: 'target_applications_list', description: 'Read the live target application and installation identities with business listener IDs. Use the returned application ID for target_logs_query.', properties: revision + ',"target_id":{"type":"string"}', required: '"binding_revision","target_id"', read_only: true },
		ToolSpec{ name: 'target_logs_query', description: 'Read target application logs with request and trace correlation, after an optional cursor. Requires an application ID from target_applications_list. Known target credentials are redacted.', properties: revision + ',"target_id":{"type":"string"},"application_id":{"type":"string"},"search":{"type":"string","maxLength":256},"limit":{"type":"integer","minimum":1,"maximum":200},"cursor":{"type":"integer","minimum":0}', required: '"binding_revision","target_id","application_id"', read_only: true },
		ToolSpec{ name: 'target_events_query', description: 'Read bounded target events with allowlisted identity, status and correlation fields. Requires a connected registered target.', properties: revision + ',"target_id":{"type":"string"},"search":{"type":"string","maxLength":256},"limit":{"type":"integer","minimum":1,"maximum":200}', required: '"binding_revision","target_id"', read_only: true },
		ToolSpec{ name: 'target_history_list', description: 'List the known application-release and runtime-upgrade operations for a registered target, including recovery state. Connect its host to refresh persisted records.', properties: revision + ',"target_id":{"type":"string"}', required: '"binding_revision","target_id"', read_only: true },
		ToolSpec{ name: 'relay_connections_list', description: 'List safe identities and authentication presence for the local or currently loaded remote Relay connection catalog. Credentials and carrier URLs remain in Desktop.', properties: revision + ',"target_id":{"type":"string"}', required: '"binding_revision"', read_only: true },
		ToolSpec{ name: 'targets_list', description: 'List Desktop-registered hosts and remote environments. Reads the current Desktop inventory without connecting.', properties: revision, required: '"binding_revision"', read_only: true },
		ToolSpec{ name: 'target_status', description: 'Read the registered remote environment status and known application inventory and installed runtime packages for a target from targets_list.', properties: revision + ',"target_id":{"type":"string"}', required: '"binding_revision","target_id"', read_only: true },
		ToolSpec{ name: 'operation_get', description: 'Read the phase and recovery state of a deployment or runtime upgrade on the connected Desktop host. Discover known operation IDs with target_status.', properties: revision + ',"operation_id":{"type":"string"}', required: '"binding_revision","operation_id"', read_only: true },
		ToolSpec{ name: 'shared_config_diff', description: 'Preview changes to match.paths for a shared remote HTTP pipeline. Pass pipeline ID and new exact paths. Returns previous paths and a plan ID without writing configuration.', properties: revision + ',"target_id":{"type":"string"},"pipeline":{"type":"string"},"paths":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":16}', required: '"binding_revision","target_id","pipeline","paths"' },
		ToolSpec{ name: 'shared_config_preflight', description: 'Compile the entire proposed remote environment and verify the reviewed source revision. Returns the same plan ID.', properties: revision + ',"target_id":{"type":"string"},"plan_id":{"type":"string"}', required: '"binding_revision","target_id","plan_id"' },
		ToolSpec{ name: 'shared_config_apply', description: 'After Desktop confirmation, publish the preflighted shared configuration and restart the target to verify effectiveness.', properties: revision + ',"target_id":{"type":"string"},"plan_id":{"type":"string"}', required: '"binding_revision","target_id","plan_id"' },
		ToolSpec{ name: 'shared_config_rollback', description: 'After Desktop confirmation, restore the exact baseline of the current applied shared configuration plan and verify effectiveness.', properties: revision + ',"target_id":{"type":"string"},"plan_id":{"type":"string"}', required: '"binding_revision","target_id","plan_id"' },
		ToolSpec{ name: 'application_release_prepare', description: 'Preflight a release of the bound independent app on a connected registered environment. Omit installation_id for first install; use the returned installation_id for updates. To preflight rollback, pass rollback_from as the current completed operation ID instead of installation_id. The previous completed artifact must be retained.', properties: revision + ',"target_id":{"type":"string"},"component":{"type":"string"},"installation_id":{"type":"string"},"rollback_from":{"type":"string"}', required: '"binding_revision","target_id","component"' },
		ToolSpec{ name: 'application_release_apply', description: 'Apply a release plan after Desktop confirmation. Use operation_get to poll until finished; the entire target environment briefly restarts.', properties: revision + ',"target_id":{"type":"string"},"plan_id":{"type":"string"}', required: '"binding_revision","target_id","plan_id"' },
		ToolSpec{ name: 'application_release_rollback', description: 'Apply a rollback plan prepared with rollback_from after Desktop confirmation. Use operation_get to poll until finished.', properties: revision + ',"target_id":{"type":"string"},"plan_id":{"type":"string"}', required: '"binding_revision","target_id","plan_id"' },
		ToolSpec{ name: 'runtime_upgrade_prepare', description: 'Preflight a runtime package switch on a connected registered environment. Use target_status to discover installed target_runtime_id values, or pass rollback_from with the latest completed upgrade operation ID. Reports affected applications and restart scope.', properties: revision + ',"target_id":{"type":"string"},"target_runtime_id":{"type":"string"},"rollback_from":{"type":"string"}', required: '"binding_revision","target_id"' },
		ToolSpec{ name: 'runtime_upgrade_apply', description: 'Apply a runtime upgrade plan after Desktop confirmation. The entire environment restarts. Poll operation_get until finished.', properties: revision + ',"target_id":{"type":"string"},"plan_id":{"type":"string"}', required: '"binding_revision","target_id","plan_id"' },
		ToolSpec{ name: 'runtime_upgrade_rollback', description: 'Apply a rollback plan prepared with rollback_from after Desktop confirmation. Poll operation_get until finished.', properties: revision + ',"target_id":{"type":"string"},"plan_id":{"type":"string"}', required: '"binding_revision","target_id","plan_id"' },
		ToolSpec{ name: 'takeover_status', description: 'Read Relay takeover state for the bound application and registered target. Returns installation_id, traffic owner, and current lease if active.', properties: revision + ',"target_id":{"type":"string"},"installation_id":{"type":"string"}', required: '"binding_revision","target_id"', read_only: true },
		ToolSpec{ name: 'takeover_prepare', description: 'Preflight the configured local Relay receiver for one authenticated application/account. Use takeover_status to discover the installation ID. The local runtime must already be running.', properties: revision + ',"target_id":{"type":"string"},"installation_id":{"type":"string"},"auth_app_id":{"type":"string"},"account":{"type":"string"}', required: '"binding_revision","target_id","installation_id","auth_app_id","account"' },
		ToolSpec{ name: 'takeover_start', description: 'After Desktop confirmation, route the prepared account to the local receiver for up to 15 minutes. Returns the lease_id to release.', properties: revision + ',"target_id":{"type":"string"},"plan_id":{"type":"string"}', required: '"binding_revision","target_id","plan_id"' },
		ToolSpec{ name: 'takeover_release', description: 'Release the exact MCP lease for this target. Returns remote ownership after verifying release. Check takeover_status and verify traffic at the original application URL.', properties: revision + ',"target_id":{"type":"string"},"lease_id":{"type":"string"}', required: '"binding_revision","target_id","lease_id"' },
		ToolSpec{ name: 'relay_create_prepare', description: 'Preview a publication using the shared Relay or remote environment selected in Desktop. Use relay_status to discover its target ID.', properties: revision + ',"target_id":{"type":"string"},"mode":{"type":"string","enum":["read_only","edit"]}', required: '"binding_revision","target_id","mode"' },
		ToolSpec{ name: 'relay_create_apply', description: 'Publish a prepared plan after confirmation in Desktop. Retrieve the Bearer in Desktop.', properties: revision + ',"plan_id":{"type":"string"}', required: '"binding_revision","plan_id"' },
		ToolSpec{ name: 'relay_status', description: 'Inspect the selected target and verify the public HTTPS MCP handshake for an active publication.', properties: revision, required: '"binding_revision"', read_only: true },
		ToolSpec{ name: 'relay_revoke', description: 'Revoke this binding’s publication and stop its local Agent. Also reclaim a dedicated Hub owned by this publication.', properties: revision + ',"publication_id":{"type":"string"}', required: '"binding_revision","publication_id"' },
	]
	return specs
}

fn register_relay_tools(mut server mcp.Server, calls chan RelayCall) ! {
	for spec in management_tool_specs() {
		name := spec.name
		properties := json.decode[map[string]json.Any]('{${spec.properties}}')!
		server.add_tool(mcp.Tool{
			name:         name
			description:  spec.description
			input_schema: '{"type":"object","additionalProperties":false,"properties":{${spec.properties}},"required":[${spec.required}]}'
			annotations:  mcp.ToolAnnotations{ read_only_hint: spec.read_only, destructive_hint: !spec.read_only, open_world_hint: !spec.read_only }
		}, fn [name, calls, properties] (ctx mcp.Context, arguments string) !mcp.ToolResult {
			if ctx.is_cancelled() { return error('cancelled') }
			for key, _ in json.decode[map[string]json.Any](arguments)! {
				if key !in properties { return error('unexpected_relay_argument') }
			}
			if name == 'shared_config_edit_prepare' {
				raw := json.decode[map[string]json.Any](arguments)!
				items := raw['edits'] or { return error('shared_config_edits_required') }
				if items !is []json.Any { return error('shared_config_edits_array_required') }
				for item in items {
					if item !is map[string]json.Any { return error('shared_config_edit_object_required') }
					for key, _ in item { if key !in ['domain', 'component', 'field', 'value', 'remove'] { return error('unexpected_shared_config_edit_argument') } }
					removing := item['remove'] or { json.Any(false) }
					if removing !is bool { return error('shared_config_remove_boolean_required') }
					if (removing.bool() && 'value' in item) || (!removing.bool() && 'value' !in item) { return error('shared_config_choose_value_or_remove') }
				}
			}
			call := RelayCall{ tool: name, args: json.decode[RelayArgs](arguments)!, deadline: time.now().unix() + 85 }
			select {
				calls <- call {
				}
				else {
					return error('Desktop busy; retry after current operation')
				}
			}
			select {
				result := <-call.reply {
					return mcp.ToolResult{ is_error: result.error, content: '[${mcp.text_content(result.value)}]' }
				}
				90 * time.second {
				}
			}
			return error('Desktop management request timed out; check status before retrying')
		})!
	}
}

// The Desktop UI owns Service and serializes this with GUI publication, revocation and rebinding.
pub fn (mut s Service) poll_relay_calls(worker host.Worker, version string, target host.SharedRelay, url string, approve fn (string) bool, inventory ManagementTargets, remotes ...host.McpHubTarget) bool {
	select {
		call := <-s.relay_calls {
			if is_ordinary_relay_tool(call.tool) {
				s.queue_ordinary_relay(call, worker, inventory, approve) or { call.reply <- host.DevelopmentReply{error: true, value: err.msg()} }
				return true
			}
			if is_package_tool(call.tool) {
				s.queue_package(call, worker, inventory, approve) or { call.reply <- host.DevelopmentReply{error: true, value: err.msg()} }
				return true
			}
			if is_lifecycle_tool(call.tool) {
				s.queue_lifecycle(call, inventory, approve) or { call.reply <- host.DevelopmentReply{error: true, value: err.msg()} }
				return true
			}
			if call.tool in ['target_probe_options_get', 'target_protocol_probe', 'target_request', 'target_diagnostics_get', 'target_applications_list', 'target_logs_query', 'target_events_query']
				|| (call.tool == 'relay_connections_list' && call.args.target_id != '') {
                if call.tool == 'target_protocol_probe' {
                    s.check_management_binding(call) or { call.reply <- host.DevelopmentReply{error: true, value: err.msg()}; return true }
                    host.validate_protocol_probe_args(host.ProtocolProbeArgs{protocol: call.args.protocol, listener: call.args.listener, path: call.args.path, message: call.args.message, timeout_ms: call.args.timeout_ms, max_items: call.args.max_items, auth_ref: call.args.auth_ref, tls_trust: call.args.tls_trust, tls_server_name: call.args.tls_server_name}) or { call.reply <- host.DevelopmentReply{error: true, value: err.msg()}; return true }
                    profiles := inventory.profiles.filter(it.id == call.args.target_id)
                    if profiles.len != 1 { call.reply <- host.DevelopmentReply{error: true, value: 'unknown_target'}; return true }
                    if !approve('业务协议探针 → ' + profiles[0].name + '\n目标：' + profiles[0].id + '\n监听器：' + call.args.listener + '\n协议：' + call.args.protocol + '\n路径：' + call.args.path + '\n认证引用：' + (if call.args.auth_ref == '' { '无' } else { call.args.auth_ref }) + '\nTLS 信任：' + call.args.tls_trust + '\n证书身份：' + (if call.args.tls_server_name == '' { '监听器回环地址' } else { call.args.tls_server_name }) + '\nWebSocket 消息可能改变应用数据；MCP 仅 initialize/tools/list。') {
                        call.reply <- host.DevelopmentReply{error: true, value: 'protocol_probe_declined'}
                        return true
                    }
                }
				s.queue_target_inspection(call, inventory) or {
					call.reply <- host.DevelopmentReply{error: true, value: err.msg()}
				}
				return true
			}
			if call.tool.starts_with('takeover_') {
				s.queue_takeover(call, worker, inventory, approve) or {
					call.reply <- host.DevelopmentReply{error: true, value: err.msg()}
				}
				return true
			}
			if call.tool.starts_with('runtime_upgrade_') {
				s.queue_runtime_upgrade(call, inventory, approve) or {
					call.reply <- host.DevelopmentReply{error: true, value: err.msg()}
				}
				return true
			}
			if call.tool.starts_with('shared_config_') {
				s.queue_shared_config(call, inventory, approve) or {
					call.reply <- host.DevelopmentReply{error: true, value: err.msg()}
				}
				return true
			}
			if call.tool.starts_with('application_release_') {
				s.queue_application_release(call, inventory, approve) or {
					call.reply <- host.DevelopmentReply{error: true, value: err.msg()}
				}
				return true
			}
			value := s.manage_request(worker, version, target, url, approve, call, inventory, ...remotes) or {
				call.reply <- host.DevelopmentReply{ error: true, value: err.msg() }
				return true
			}
			if call.tool == 'relay_status' && s.relay_public_url != '' && !isnil(s.relay) {
				spawn probe_relay_status(call.reply, value, s.relay_public_url, s.relay.token, s.relay.grant)
			} else {
				call.reply <- host.DevelopmentReply{ value: value }
			}
			return true
		}
		else {
		}
	}
	return false
}

fn (mut s Service) manage_request(worker host.Worker, version string, target host.SharedRelay, url string, approve fn (string) bool, call RelayCall, inventory ManagementTargets, remotes ...host.McpHubTarget) !string {
	if call.tool in ['target_history_list', 'relay_connections_list'] {
		s.check_management_binding(call)!
		return inventory.inspection_inventory(call.tool, call.args.target_id)!
	}
	if call.tool == 'host_inventory_get' {
		s.check_management_binding(call)!
		return inventory.host_inventory(call.args.host_id)!
	}
	if call.tool == 'operation_get' {
		s.check_management_binding(call)!
		return inventory.operation_status(call.args.operation_id)!
	}
	if call.tool in ['targets_list', 'target_status'] {
		s.check_management_binding(call)!
		return inventory.report(call.tool, call.args.target_id)!
	}
	return s.manage_relay(worker, version, target, url, approve, call, ...remotes)!
}

fn (s &Service) check_management_binding(call RelayCall) ! {
	if call.deadline <= time.now().unix() { return error('management_request_expired') }
	selection := s.selection()
	if call.args.binding_revision != selection.generation || selection.application.id == '' || s.access.is_revoked() {
		return error('stale_binding_revision: call context_get')
	}
}

fn (mut s Service) manage_relay(worker host.Worker, version string, selected host.SharedRelay, url string, approve fn (string) bool, call RelayCall, remotes ...host.McpHubTarget) !string {
	remote := if remotes.len == 1 { remotes[0] } else { host.McpHubTarget{} }
	mut target := selected
	if remote.project_id != '' {
		endpoint := urllib.parse(url) or { urllib.URL{} }
		target = host.SharedRelay{ id: remote.project_id, name: 'Desktop MCP Hub', relay_id: 'edge', url: 'wss://' + endpoint.host + '/vhttpd/relay/desktop-mcp', token: 'pending' }
	}
	s.check_management_binding(call)!
	selection := s.selection()
	args := call.args
	match call.tool {
		'relay_create_prepare' {
			if !isnil(s.relay) || s.remote_hub_id != '' {
				return error('relay_already_published: revoke it first')
			}
			if args.target_id == '' || args.target_id != target.id {
				return error('select a Relay target in Desktop')
			}
			if args.mode !in ['read_only', 'edit'] { return error('invalid_relay_mode') }
			validate_relay_endpoint(target, url)!
			carrier := urllib.parse(target.url)!
			if !os.is_executable(selection.binary) {
				return error('select a runtime package in Desktop')
			}
			s.relay_plan = RelayPlan{ id: rand.bytes(16)!.hex(), target: target, remote: remote, url: url, mode: args.mode, generation: selection.generation, expires: time.now().unix() + 300 }
			return json.encode({
				'plan_id':                       json.Any(s.relay_plan.id)
				'target_id':                     json.Any(target.id)
				'carrier_path':                  json.Any(carrier.path)
				'hub_source':                    json.Any(if remote.project_id == '' {
					'existing'
				} else {
					'dedicated'
				})
				'public_url':                    json.Any(url)
				'mode':                          json.Any(args.mode)
				'expires_at':                    json.Any(s.relay_plan.expires)
				'grant_ttl_seconds':             json.Any(3600)
				'runtime_impact':                json.Any(if args.mode == 'edit' {
					'all_applications_in_environment'
				} else {
					'read_only'
				})
				'desktop_confirmation_required': json.Any(true)
			})
		}
		'relay_create_apply' {
			plan := s.relay_plan
			if args.plan_id == '' || plan.id != args.plan_id || plan.generation != selection.generation {
				return error('invalid_relay_plan')
			}
			if plan.applied { return s.relay_status(target.id) }
			if plan.expires <= time.now().unix() || plan.target != target || plan.remote.server.id != remote.server.id || plan.remote.project_id != remote.project_id || plan.remote.runtime_id != remote.runtime_id || plan.url != url || !isnil(s.relay) {
				return error('stale_relay_plan: prepare again')
			}
			impact := if plan.mode == 'edit' {
				'允许编辑应用，并启停影响整个环境的运行时。'
			} else {
				'只读访问当前应用。'
			}
			remote_impact := if remote.project_id == '' {
				''
			} else {
				'\n在远端服务器 ${remote.server.name} 启动独立 Hub，需要配置 HTTPS 网关回源。'
			}
			if !approve('${selection.project.name} / ${selection.application.label}\n${plan.url}\n${impact}授权一小时。${remote_impact}') {
				s.relay_plan = RelayPlan{}
				return error('relay_publication_denied')
			}
			if plan.expires <= time.now().unix() || call.deadline <= time.now().unix()
				|| s.relay_plan.id != plan.id || s.selection().generation != plan.generation
				|| s.access.is_revoked() {
				return error('stale_relay_plan: prepare again')
			}
			if remote.project_id != '' {
				carrier_token := rand.bytes(32)!.hex()
				ports := remote.request(plan.id, carrier_token, false) or {
					s.remote_hub = remote
					s.remote_hub_id = plan.id
					s.reclaim_remote_hub()
					return error('remote_hub_creation_failed: call relay_status')
				}
				s.publish_relay(worker, version, host.SharedRelay{ ...target, token: carrier_token }, url, plan.mode == 'edit') or {
					s.remote_hub = remote
					s.remote_hub_id = plan.id
					s.reclaim_remote_hub()
					return error('relay_publication_failed: call relay_status')
				}
				s.remote_hub = remote
				s.remote_hub_id = plan.id
				s.remote_hub_ports = ports
			} else {
				s.publish_relay(worker, version, target, url, plan.mode == 'edit') or {
					return error('relay_publication_failed: check the selected runtime and Relay in Desktop')
				}
			}
			s.relay_plan = RelayPlan{ ...plan, applied: true }
		}
		'relay_status' {}
		'relay_revoke' {
			if args.publication_id == '' {
				return error('publication_id_required: call relay_status')
			}
			active_id := if s.relay_publication_id != '' {
				s.relay_publication_id
			} else {
				s.remote_hub_id
			}
			if active_id != '' && args.publication_id != active_id {
				return error('publication_changed: call relay_status')
			}
			s.revoke_relay()
		}
		else { return error('unknown_relay_tool') }
	}
	return s.relay_status(target.id)
}

fn (s &Service) relay_status(target_id string) string {
	return json.encode({
		'target_id':              json.Any(target_id)
		'published_target_id':    json.Any(s.relay_target_id)
		'publication_id':         json.Any(if s.relay_publication_id != '' {
			s.relay_publication_id
		} else {
			s.remote_hub_id
		})
		'hub_http_port':          json.Any(s.remote_hub_ports.http_port)
		'hub_carrier_port':       json.Any(s.remote_hub_ports.carrier_port)
		'remote_cleanup_pending': json.Any(s.remote_hub_id != '' && s.relay_public_url == '')
		'public_url':             json.Any(s.relay_public_url)
		'mode':                   json.Any(s.relay_mode)
		'expires_at':             json.Any(s.relay_expires)
		'state':                  json.Any(if s.relay_public_url == '' {
			'inactive'
		} else {
			'agent_started'
		})
	})
}
