module devmcp

import host
import json2 as json

fn ordinary_relay_tool_specs(revision string) []ToolSpec {
	target := ',"target_id":{"type":"string"}'
	mut specs := config_edit_tool_specs(revision)
	specs << [
		ToolSpec{ name: 'relay_config_get', description: 'Discover existing Relay definitions, including configurations not created by MCP, and their relative source files and safe editable fields. Omitting relay_id lists all. Credentials and full carrier URLs stay private. Requires effective running configuration.', properties: revision + target + ',"relay_id":{"type":"string"}', required: '"binding_revision"', read_only: true },
		ToolSpec{ name: 'relay_config_edit_prepare', description: 'Preview a field patch to an existing Relay from its real source, including an include file, without ownership markers. Preserve unrelated bytes and credentials. Supports hub/agent conversion, optional field removal and disjoint Relay fields in multiple include files. Updates edit real field sources; remove_fields deletes assignments; new fields use the mode source. Conversion removes incompatible mode fields and requires saved connection_id for agent or listener and authentication for hub. Only the runtime WebSocket carrier is supported; connection_id references private credentials and agent URL. No raw token, URL or TOML. Requires separate edit_preflight before apply.', properties: revision + target + ',"relay_id":{"type":"string"},"connection_id":{"type":"string"},"updates":{"type":"object","additionalProperties":false,"properties":{"mode":{"type":"string","enum":["hub","agent"]},"carrier":{"type":"string","enum":["websocket"]},"node_id":{"type":"string"},"path":{"type":"string"},"listener":{"type":"string"},"autostart":{"type":"boolean"},"max_channels":{"type":"integer"},"channel_buffer":{"type":"integer"},"reconnect_delay_ms":{"type":"integer"}}},"remove_fields":{"type":"array","uniqueItems":true,"items":{"type":"string","enum":["mode","carrier","node_id","path","listener","autostart","max_channels","channel_buffer","reconnect_delay_ms","token","url","auth"]}}', required: '"binding_revision","relay_id"' },
		ToolSpec{ name: 'relay_config_edit_preflight', description: 'Compile the entire existing-Relay edit using runtime Admin validation, rechecking full source revision and boot identity. Does not publish or restart. The exact plan must pass preflight before apply.', properties: revision + target + ',"plan_id":{"type":"string"}', required: '"binding_revision","plan_id"' },
		ToolSpec{ name: 'relay_database_resources_list', description: 'List configured MySQL Relay client bindings and database exports in the bound local or registered remote runtime. Returns resource, Relay and route identities without credentials. Requires a running effective configuration. Saved configuration is not proof of connectivity.', properties: revision + target, required: '"binding_revision"', read_only: true },
		ToolSpec{ name: 'relay_database_probe', description: 'Verify a configured MySQL Relay resource using the existing vhttpd Agent carrier and a fixed SELECT 1 AS relay_probe query. No arbitrary SQL, database URLs or credentials. Returns safe configuration/carrier/transport/database/response failure stages. Does not register another Agent, retry a sent query, restart or alter configuration. Requires runtime support for the dedicated probe endpoint.', properties: revision + target + ',"resource_id":{"type":"string"}', required: '"binding_revision","resource_id"', read_only: true },
		ToolSpec{ name: 'relay_connection_save_prepare', description: 'Preflight a native Relay catalog create/update. Omit target_id for local catalog; otherwise select a registered environment on the connected host. Credentials come from a verified hub_target_id+relay_id, or source_connection_id from the local Desktop catalog. No token or URL input. Saving does not configure or connect a runtime.', properties: revision + target + ',"connection_id":{"type":"string"},"source_connection_id":{"type":"string"},"hub_target_id":{"type":"string"},"relay_id":{"type":"string"},"name":{"type":"string"}', required: '"binding_revision","name"' },
		ToolSpec{ name: 'relay_connection_delete_prepare', description: 'Preflight deleting one saved catalog record. Deployed configurations are independent copies and remain unchanged; restore them separately before reclaiming a Relay.', properties: revision + target + ',"connection_id":{"type":"string"}', required: '"binding_revision","connection_id"' },
		ToolSpec{ name: 'relay_connection_probe', description: 'Probe a saved native Relay from Desktop: verify WebSocket and Relay authentication using a temporary non-registering session. Does not represent a running Agent. Check relay_runtime_status and real traffic separately.', properties: revision + target + ',"connection_id":{"type":"string"}', required: '"binding_revision","connection_id"', read_only: true },
		ToolSpec{ name: 'relay_config_prepare', description: 'Preflight a Desktop MCP-owned ordinary Relay configuration in the bound local environment or registered remote environment. Hub mode creates an authenticated WebSocket carrier on an HTTP listener; verify_path optionally exposes an HTTP forwarding route on that listener; agent mode references a saved connection and existing adapter. Agent starts disabled. The whole configuration is compiled. Apply restarts the entire environment.', properties: revision + target + ',"mode":{"type":"string","enum":["hub","agent"]},"relay_id":{"type":"string"},"connection_id":{"type":"string"},"adapter_id":{"type":"string"},"route":{"type":"string"},"port":{"type":"integer","minimum":1024,"maximum":65535},"path":{"type":"string"},"verify_path":{"type":"string"}', required: '"binding_revision","mode","relay_id"' },
		ToolSpec{ name: 'relay_agent_control_prepare', description: 'Preflight start/stop for an MCP-owned agent. Pins source revision and boot identity. This runtime implements lifecycle through persisted autostart and whole-environment restart, which affects every application.', properties: revision + target + ',"relay_id":{"type":"string"},"action":{"type":"string","enum":["start","stop"]}', required: '"binding_revision","relay_id","action"' },
		ToolSpec{ name: 'relay_runtime_status', description: 'Read safe live agent states for one Relay. Counts are process-wide, not proof of a particular route. Verify an actual request through the remote forwarding path after start.', properties: revision + target + ',"relay_id":{"type":"string"}', required: '"binding_revision","relay_id"', read_only: true },
		ToolSpec{ name: 'relay_operation_get', description: 'Read asynchronous catalog/configuration/lifecycle/restore operations for the current binding generation. A failed or uncertain publish requires inspecting the live runtime before retrying or restoring.', properties: revision + ',"operation_id":{"type":"string"}', required: '"binding_revision","operation_id"', read_only: true },
	]
	for name in ['relay_connection_save_apply', 'relay_connection_delete_apply', 'relay_config_apply',
		'relay_agent_control_apply', 'relay_config_restore', 'relay_config_edit_apply', 'relay_config_edit_restore'] {
		specs << ToolSpec{ name: name, description: 'Execute the exact reviewed plan after Desktop confirmation. Returns accepted operation_id before work; poll relay_operation_get. Config and start/stop restart the entire target environment. Restore replays the exact baseline only if source revision is still current. Do not pass secrets.', properties: revision + target + ',"plan_id":{"type":"string"}', required: '"binding_revision","plan_id"' }
	}
	return specs
}

fn is_ordinary_relay_tool(name string) bool {
	return is_config_edit_tool(name) || name in ['relay_config_get', 'relay_config_edit_prepare', 'relay_config_edit_preflight', 'relay_config_edit_apply', 'relay_config_edit_restore', 'relay_database_resources_list', 'relay_database_probe', 'relay_connection_save_prepare', 'relay_connection_save_apply',
		'relay_connection_delete_prepare', 'relay_connection_delete_apply', 'relay_connection_probe',
		'relay_config_prepare', 'relay_config_apply', 'relay_config_restore',
		'relay_agent_control_prepare', 'relay_agent_control_apply', 'relay_runtime_status',
		'relay_operation_get']
}

fn (s &Service) queue_ordinary_relay(call RelayCall, local host.Worker, inventory ManagementTargets, approve fn (string) bool) ! {
	s.check_management_binding(call)!
	a := call.args
	if call.tool in ['relay_operation_get', 'shared_config_operation_get'] {
		operations := inventory.server.mcp_relay_operations.filter(it.operation_id == a.operation_id && it.generation == a.binding_revision)
		if operations.len != 1 { return error('unknown_relay_operation_retry_status') }
		call.reply <- host.DevelopmentReply{ value: json.encode(operations[0]) }
		return
	}
	if a.target_id != '' && (!inventory.server.connected || !inventory.profiles.any(it.id == a.target_id && it.server_id == inventory.server.server_id)) {
		return error('connect_registered_relay_target_host')
	}
	if a.hub_target_id != '' && (!inventory.server.connected || !inventory.profiles.any(it.id == a.hub_target_id && it.server_id == inventory.server.server_id)) {
		return error('connect_hub_reference_host')
	}
	// Old applied plans remain usable for exact restoration; Worker owns their identities.
	if call.tool.ends_with('_apply') || call.tool in ['relay_config_restore', 'relay_config_edit_restore', 'shared_config_edit_restore', 'config_history_restore_undo'] {
		plans := inventory.server.mcp_relay_previews.filter(it.plan_id == a.plan_id && it.generation == a.binding_revision && it.target_id == a.target_id)
		if plans.len != 1 || !host.ordinary_relay_apply_matches(call.tool, plans[0].action) {
			return error('invalid_ordinary_relay_plan')
		}
		reviewed := plans[0]
		if call.tool in ['relay_config_edit_apply', 'shared_config_edit_apply', 'config_history_restore_apply'] && reviewed.preflight_required { return error('relay_edit_preflight_required') }
		restoring := call.tool in ['relay_config_restore', 'relay_config_edit_restore', 'shared_config_edit_restore', 'config_history_restore_undo']
		from := if restoring { reviewed.after } else { reviewed.before }
		to := if restoring { reviewed.before } else { reviewed.after }
		effect := if call.tool in ['relay_connection_save_apply', 'relay_connection_delete_apply'] {
			'只写连接库，不启动或停止已部署的配置副本。'
		} else {
			'运行配置会改变，并重启整个目标环境，影响其中全部应用；恢复只接受匹配的原始版本。'
		}
		target := if a.target_id == '' {
			s.access.selection().project.name
		} else {
			inventory.profiles.filter(it.id == a.target_id)[0].name
		}
		exposure := if reviewed.action == 'hub' {
			'\n新增监听：0.0.0.0:${reviewed.port}；HTTP 转发路径：${reviewed.verify_path}'
		} else {
			''
		}
		label := if reviewed.action in ['shared_edit', 'history_restore'] { '共享配置操作' } else { '普通 Relay 操作' }
		if !approve('${label} → ${target}\n操作：${reviewed.action} / ${call.tool}\nRelay：${reviewed.relay_id}；连接：${reviewed.connection_id}\n来源：${reviewed.sources.join(', ')}；删除：${reviewed.removed_fields.join(', ')}；字段：${reviewed.fields.join(', ')}\n修改前：${json.encode(from)}\n修改后：${json.encode(to)}\n名称：${reviewed.name}；适配器：${reviewed.adapter_id}；路由：${reviewed.route}${exposure}\n对端：${reviewed.peer}；凭据引用：${reviewed.credential_source}\n${effect}\n已审阅计划 ID：${a.plan_id}') {
			return error('ordinary_relay_operation_denied')
		}
	}
	s.check_management_binding(call)!
	select {
		inventory.worker.commands <- host.ServerCommand{ action: .mcp_ordinary_relay, mcp_ordinary_relay: host.McpOrdinaryRelayRequest{ tool: call.tool, target_id: a.target_id, hub_target_id: a.hub_target_id, connection_id: a.connection_id, source_connection_id: a.source_connection_id, relay_id: a.relay_id, name: a.name, mode: if call.tool == 'relay_config_edit_prepare' { 'edit' } else if call.tool == 'relay_agent_control_prepare' {
			a.action
		} else {
			a.mode
		}, port: a.port, path: if a.path == '' { '/vhttpd/relay' } else { a.path }, verify_path: a.verify_path, route: a.route, adapter_id: a.adapter_id, resource_id: a.resource_id, updates: a.updates, edits: a.edits, version_id: a.version_id, remove_fields: a.remove_fields, plan_id: a.plan_id, generation: a.binding_revision, deadline: call.deadline, access: s.access, local: local, reply: call.reply } } {
		}
		else {
			return error('Desktop server worker busy')
		}
	}
}
