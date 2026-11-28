module devmcp

import host
import json2 as json

fn lifecycle_tool_specs(revision string) []ToolSpec {
	mut specs := [
		ToolSpec{ name: 'host_register', description: 'After Desktop confirmation, register a key-authenticated SSH host. No connection is opened. Omit credential_host_id to use local SSH configuration; provide a saved host ID to reuse its key reference. Never accepts passwords or private-key paths. Repeating the exact endpoint and name returns the same host ID.', properties: revision + ',"name":{"type":"string","maxLength":64},"ssh_host":{"type":"string"},"ssh_user":{"type":"string"},"ssh_port":{"type":"integer","minimum":1,"maximum":65535},"credential_host_id":{"type":"string"}', required: '"binding_revision","name","ssh_host"' },
		ToolSpec{ name: 'host_disconnect', description: 'After Desktop confirmation, disconnect this host SSH control session. Does not stop remote instances. Rejects unfinished operations or another connected host. Repeating a disconnect is safe.', properties: revision + ',"host_id":{"type":"string"}', required: '"binding_revision","host_id"' },
		ToolSpec{ name: 'environment_discover', description: 'Refresh environments discovered from managed directories and running processes on the connected saved host. Desktop discovery caches profiles automatically. Returns safe candidate IDs and whether runtime bindings are managed; no paths or credentials. Use environment_adopt_prepare/apply to verify live Admin identity before using an existing environment.', properties: revision + ',"host_id":{"type":"string"}', required: '"binding_revision","host_id"', read_only: true },
		ToolSpec{ name: 'environment_adopt_prepare', description: 'Preflight an existing discovered environment: pin configuration revision and authenticated Admin boot identity. Requires its Admin API to be running. Does not rewrite config, add ownership markers, restart or convert externally managed instances.', properties: revision + ',"host_id":{"type":"string"},"target_id":{"type":"string"}', required: '"binding_revision","host_id","target_id"' },
		ToolSpec{ name: 'environment_adopt_apply', description: 'After Desktop confirmation, recheck and persist the verified discovered target. Uses the five-minute preflight plan and returns an operation ID. Poll host_operation_get, then verify business HTTP. Repeating the same current plan is idempotent.', properties: revision + ',"host_id":{"type":"string"},"plan_id":{"type":"string"}', required: '"binding_revision","host_id","plan_id"' },
		ToolSpec{ name: 'host_connect', description: 'Connect a saved key-authenticated host using Desktop SSH. Unknown fingerprints require Desktop UI trust. Password hosts require Desktop login. Returns accepted operation ID; poll host_operation_get. Never accepts credentials.', properties: revision + ',"host_id":{"type":"string"}', required: '"binding_revision","host_id"' },
		ToolSpec{ name: 'host_operation_get', description: 'Read this binding generation’s asynchronous host connection, environment creation/adoption, instance start or stop result. Records last for this Desktop session; use instance_status after reconnect.', properties: revision + ',"operation_id":{"type":"string"}', required: '"binding_revision","operation_id"', read_only: true },
		ToolSpec{ name: 'instance_status', description: 'Probe one registered managed instance over the connected host SSH session. Reports running or stopped independently of its Admin API. This is process status, not business readiness; verify target_request after start.', properties: revision + ',"target_id":{"type":"string"}', required: '"binding_revision","target_id"', read_only: true },
		ToolSpec{ name: 'environment_create_prepare', description: 'Preflight a new managed environment on a connected saved host: installed runtime, template, name and available ports. Returns a five-minute immutable plan. Existing directories are never adopted or overwritten. Templates: environment (Admin only), vjsx-http or vjsx-api. Creation also starts the instance.', properties: revision + ',"host_id":{"type":"string"},"name":{"type":"string","maxLength":64},"runtime_id":{"type":"string"},"template":{"type":"string","enum":["environment","vjsx-http","vjsx-api"]},"admin_port":{"type":"integer","minimum":1024,"maximum":65535},"web_port":{"type":"integer","minimum":1024,"maximum":65535}', required: '"binding_revision","host_id","name","runtime_id","admin_port"' },
	]
	for action in ['start', 'stop'] {
		specs << ToolSpec{ name: 'instance_${action}_prepare', description: 'Preflight managed instance ${action}. Pins configuration and exact process identity for five minutes. Stop affects every application in that environment and uses graceful SIGTERM only.', properties: revision + ',"target_id":{"type":"string"}', required: '"binding_revision","target_id"' }
	}
	for action in ['environment_create', 'instance_start', 'instance_stop'] {
		specs << ToolSpec{ name: '${action}_apply', description: 'After Desktop confirmation, execute the immutable preflight plan. Returns accepted operation ID before remote work; poll host_operation_get. Reusing this plan is idempotent. Verify live instance_status and business HTTP separately.', properties: revision + ',"host_id":{"type":"string"},"plan_id":{"type":"string"}', required: '"binding_revision","host_id","plan_id"' }
	}
	return specs
}

fn is_lifecycle_tool(name string) bool {
	return name in ['host_register', 'host_disconnect', 'environment_discover',
		'environment_adopt_prepare', 'environment_adopt_apply', 'host_connect', 'host_operation_get',
		'instance_status', 'environment_create_prepare', 'environment_create_apply',
		'instance_start_prepare', 'instance_start_apply', 'instance_stop_prepare', 'instance_stop_apply']
}

fn (s &Service) queue_lifecycle(call RelayCall, inventory ManagementTargets, approve fn (string) bool) ! {
	s.check_management_binding(call)!
	a := call.args
	if call.tool == 'host_register' {
		mut identity := ''
		mut source := '本机 SSH 配置'
		if a.credential_host_id != '' {
			matches := inventory.servers.filter(it.id == a.credential_host_id && it.auth_method == 'key')
			if matches.len != 1 { return error('unknown_key_credential_host') }
			identity = matches[0].identity_file
			source = matches[0].name
		}
		server := host.RemoteServer{ name: a.name, ssh_host: a.ssh_host, ssh_user: a.ssh_user, ssh_port: a.ssh_port, identity_file: identity }
		host.validate_mcp_host_registration(server)!
		if !approve('登记 SSH 主机 → ${a.name}\n地址：${a.ssh_user}@${a.ssh_host}:${a.ssh_port}\n密钥引用来源：${source}\n只保存连接记录，不建立连接或授予主机信任。') {
			return error('host_registration_denied')
		}
		s.check_management_binding(call)!
		select {
			inventory.worker.commands <- host.ServerCommand{ action: .mcp_lifecycle, mcp_lifecycle: host.McpLifecycleRequest{ tool: call.tool, server: server, generation: a.binding_revision, deadline: call.deadline, access: s.access, reply: call.reply } } {
			}
			else {
				return error('Desktop server worker busy')
			}
		}
		return
	}
	if call.tool == 'host_operation_get' {
		found := inventory.server.mcp_host_operations.filter(it.operation_id == a.operation_id && it.generation == a.binding_revision)
		if found.len != 1 { return error('unknown_host_operation_retry_status') }
		call.reply <- host.DevelopmentReply{ value: json.encode(found[0]) }
		return
	}
	mut host_id := a.host_id
	if call.tool.starts_with('instance_') && !call.tool.ends_with('_apply') {
		targets := inventory.profiles.filter(it.id == a.target_id)
		if targets.len != 1 { return error('unknown_target: call targets_list') }
		host_id = targets[0].server_id
	}
	servers := inventory.servers.filter(it.id == host_id)
	if servers.len != 1 { return error('unknown_host: call targets_list') }
	if call.tool !in ['host_connect', 'host_disconnect'] && (!inventory.server.connected || inventory.server.server_id != host_id) {
		return error('connect_registered_host_first')
	}
	if call.tool == 'host_disconnect' {
		if inventory.server.busy || (inventory.server.connected && inventory.server.server_id != host_id) {
			return error('host_worker_busy_or_wrong_host')
		}
		if !approve('断开 SSH 主机 → ${servers[0].name}\n只关闭 Desktop 的主机管理连接；远端实例继续运行。') {
			return error('host_disconnect_denied')
		}
	} else if call.tool == 'host_connect' {
		if !approve('连接已保存的主机 → ${servers[0].name}\n认证由 Desktop 管理；首次指纹仍需在界面核对。') {
			return error('host_connection_denied')
		}
	} else if call.tool.ends_with('_apply') {
		p := inventory.server.mcp_lifecycle_preview
		if p.plan_id != a.plan_id || p.plan_id == '' || p.host_id != host_id || p.generation != a.binding_revision || p.action != call.tool.all_before('_apply').all_after('instance_').replace('environment_', '') {
			return error('invalid_lifecycle_plan')
		}
		details := if p.action == 'create' {
			'\n模板：${p.template}\nAdmin 端口：${p.admin_port}；业务端口：${p.web_port}'
		} else {
			''
		}
		impact := if p.action == 'adopt' {
			'仅验证并保存连接记录，不重启或改写远端配置。'
		} else {
			'启停会影响整个环境中的全部应用。'
		}
		if !approve('远端实例操作 → ${servers[0].name} / ${p.name}\n操作：${p.action}\n运行包：${p.runtime_id}${details}\n${impact}计划：${p.plan_id}') {
			return error('instance_operation_denied')
		}
	}
	s.check_management_binding(call)!
	select {
		inventory.worker.commands <- host.ServerCommand{ action: .mcp_lifecycle, mcp_lifecycle: host.McpLifecycleRequest{ tool: call.tool, server: servers[0], target_id: a.target_id, plan_id: a.plan_id, name: a.name, template: a.template, runtime_id: a.runtime_id, web_port: a.web_port, admin_port: a.admin_port, generation: a.binding_revision, deadline: call.deadline, access: s.access, reply: call.reply } } {
		}
		else {
			return error('Desktop server worker busy')
		}
	}
}
