module devmcp

import host
import time

fn (s &Service) queue_runtime_upgrade(call RelayCall, inventory ManagementTargets, approve fn (string) bool) ! {
	s.check_management_binding(call)!
	args := call.args
	profiles := inventory.profiles.filter(it.id == args.target_id)
	if profiles.len != 1 || !inventory.server.connected || inventory.server.busy
		|| profiles[0].server_id != inventory.server.server_id {
		return error('connect the registered target host in Desktop: call targets_list')
	}
	profile := profiles[0]
	action := call.tool.all_after('runtime_upgrade_')
	if action == 'prepare' {
		if (args.target_runtime_id == '') == (args.rollback_from == '') {
			return error('provide exactly one of target_runtime_id or rollback_from')
		}
	} else {
		p := inventory.server.mcp_upgrade_preview
		kind := if action == 'rollback' { 'rollback' } else { 'upgrade' }
		if p.plan_id == '' || p.plan_id != args.plan_id || p.target_id != profile.id || p.kind != kind {
			return error('invalid_upgrade_plan: prepare again')
		}
		if p.phase == 'prepared' {
			if p.expires_at <= time.now().unix() {
				return error('stale_upgrade_plan: prepare again')
			}
			label := if kind == 'rollback' { '回滚运行包' } else { '升级运行包' }
			if !approve('${label} → ${inventory.server.server.name} / ${profile.name}\n${p.previous_version} → ${p.target_version}\n目标运行包：${p.target_runtime_id}\n整个环境将短暂重启，影响 ${p.applications.len} 个应用。\n操作 ID：${p.operation_id}') {
				return error('runtime_upgrade_denied')
			}
			s.check_management_binding(call)!
		}
	}
	select {
		inventory.worker.commands <- host.ServerCommand{
			action:              .mcp_runtime_upgrade
			mcp_runtime_upgrade: host.McpUpgradeRequest{
				target_id:         profile.id
				server_id:         profile.server_id
				target_runtime_id: args.target_runtime_id
				rollback_from:     args.rollback_from
				plan_id:           args.plan_id
				action:            action
				generation:        args.binding_revision
				deadline:          call.deadline
				access:            s.access
				reply:             call.reply
			}
		} {
		}
		else {
			return error('Desktop server worker busy')
		}
	}
}
