module devmcp

import host

fn (s &Service) queue_shared_config(call RelayCall, inventory ManagementTargets, approve fn (string) bool) ! {
	s.check_management_binding(call)!
	args := call.args
	profiles := inventory.profiles.filter(it.id == args.target_id)
	if profiles.len != 1 || !inventory.server.connected || inventory.server.busy
		|| profiles[0].server_id != inventory.server.server_id || profiles[0].runtime_id == '' {
		return error('connect the registered target host in Desktop: call targets_list')
	}
	profile := profiles[0]
	action := call.tool.all_after('shared_config_')
	if action in ['apply', 'rollback'] {
		label := if action == 'rollback' { '回滚' } else { '应用' }
		preview := inventory.server.mcp_shared_config_preview
		if preview.plan_id == '' || preview.plan_id != args.plan_id || preview.target_id != profile.id {
			return error('invalid_shared_config_plan')
		}
		before, after := if action == 'rollback' { preview.after.join(', '), preview.before.join(', ') } else { preview.before.join(', '), preview.after.join(', ') }
		if !approve('${label}远端共享配置 → ${inventory.server.server.name} / ${profile.name}\nPipeline：${preview.pipeline}\n路径：${before} → ${after}\n整个目标运行环境将短暂重启。计划 ID：${args.plan_id}') {
			return error('shared_config_denied')
		}
		s.check_management_binding(call)!
	}
	select {
		inventory.worker.commands <- host.ServerCommand{action: .mcp_shared_config, mcp_shared_config: host.McpSharedConfigRequest{
			action: action
			target_id: profile.id
			server_id: profile.server_id
			runtime_id: profile.runtime_id
			plan_id: args.plan_id
			pipeline: args.pipeline
			paths: args.paths
			generation: args.binding_revision
			deadline: call.deadline
			access: s.access
			reply: call.reply
		}} {}
		else { return error('Desktop server worker busy') }
	}
}
