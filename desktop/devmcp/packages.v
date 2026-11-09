module devmcp

import host
import json2 as json

fn package_tool_specs(revision string) []ToolSpec {
	mut specs := [
		ToolSpec{ name: 'runtime_package_operation_get', description: 'Query asynchronous official download, local or remote package installation, or local package selection. After selection call context_get again for the new binding_revision, then query this operation. Records and downloads live for this Desktop session.', properties: revision + ',"operation_id":{"type":"string"}', required: '"binding_revision","operation_id"', read_only: true },
		ToolSpec{ name: 'runtime_download_prepare', description: 'Resolve one explicit official release tag and platform into a five-minute download plan. Uses official GitHub metadata and SHA256 files; never accepts a URL or filesystem path. Download does not install or change selection.', properties: revision + ',"tag":{"type":"string"},"platform":{"type":"string","enum":["macos-arm64","linux-amd64","linux-arm64"]}', required: '"binding_revision","tag","platform"' },
		ToolSpec{ name: 'runtime_install_prepare', description: 'Preflight a completed download ID for installation. Omit host_id for local installation; otherwise use a connected saved host of the matching platform. Installation preserves the current runtime selection and running instances.', properties: revision + ',"download_id":{"type":"string"},"host_id":{"type":"string"}', required: '"binding_revision","download_id"' },
		ToolSpec{ name: 'runtime_package_select_prepare', description: 'Probe a known local package ID against the entire bound environment and pin binary and config revisions. Apply requires the local runtime to be stopped. For remote instances use runtime_upgrade_prepare/apply/rollback.', properties: revision + ',"package_id":{"type":"string"}', required: '"binding_revision","package_id"' },
	]
	for action in ['download', 'install', 'package_select'] {
		specs << ToolSpec{ name: 'runtime_${action}_apply', description: 'Execute the reviewed runtime package plan after Desktop confirmation. Returns accepted operation_id before remote or download work. Poll runtime_package_operation_get; repeat the current plan safely. Omit host_id for local operations. Local selection invalidates previous change previews and increments binding_revision; call context_get again.', properties: revision + ',"plan_id":{"type":"string"},"host_id":{"type":"string"}', required: '"binding_revision","plan_id"' }
	}
	return specs
}

fn is_package_tool(name string) bool {
	return name in ['runtime_package_operation_get', 'runtime_download_prepare',
		'runtime_download_apply', 'runtime_install_prepare', 'runtime_install_apply',
		'runtime_package_select_prepare', 'runtime_package_select_apply']
}

fn (s &Service) queue_package(call RelayCall, local host.Worker, inventory ManagementTargets, approve fn (string) bool) ! {
	s.check_management_binding(call)!
	a := call.args
	if call.tool == 'runtime_package_operation_get' {
		ops := inventory.server.mcp_package_operations.filter(it.operation_id == a.operation_id && it.binding_revision == a.binding_revision)
		if ops.len != 1 { return error('unknown_package_operation_refresh_context_or_retry') }
		call.reply <- host.DevelopmentReply{ value: json.encode(ops[0]) }
		return
	}
	if a.host_id != '' && (!inventory.server.connected || inventory.server.server_id != a.host_id || !inventory.servers.any(it.id == a.host_id)) {
		return error('connect_saved_install_host_first')
	}
	if call.tool.ends_with('_apply') {
		p := inventory.server.mcp_package_preview
		if p.plan_id == '' || p.plan_id != a.plan_id || p.generation != a.binding_revision || p.host_id != a.host_id || p.action != call.tool.all_before('_apply').all_after('runtime_') {
			return error('invalid_package_plan')
		}
		target := if p.host_id == '' { '本机 Mac' } else { inventory.server.server.name }
		effect := if p.action == 'download' {
			'仅下载并校验官方文件，不安装或切换。'
		} else if p.action == 'install' {
			'安装运行包，保持现有运行包选择与实例不变。'
		} else {
			'切换本机运行包；运行时必须停止。旧变更预览失效，须重新读取上下文。'
		}
		if !approve('运行包操作 → ${target}\n操作：${p.action}；平台：${p.platform}\n版本：${p.tag}\n下载 ID：${p.download_id}；运行包 ID：${p.package_id}\n${effect}\n计划：${p.plan_id}') {
			return error('runtime_package_operation_denied')
		}
	}
	s.check_management_binding(call)!
	select {
		inventory.worker.commands <- host.ServerCommand{ action: .mcp_package, mcp_package: host.McpPackageRequest{ tool: call.tool, host_id: a.host_id, tag: a.tag, platform: a.platform, download_id: a.download_id, package_id: a.package_id, plan_id: a.plan_id, generation: a.binding_revision, deadline: call.deadline, access: s.access, local: local, reply: call.reply } } {
		}
		else {
			return error('Desktop server worker busy')
		}
	}
}
