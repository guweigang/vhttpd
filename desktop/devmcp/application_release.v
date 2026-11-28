module devmcp

import host
import time

fn (s &Service) queue_application_release(call RelayCall, inventory ManagementTargets, approve fn (string) bool) ! {
	s.check_management_binding(call)!
	args := call.args
	profiles := inventory.profiles.filter(it.id == args.target_id)
	if profiles.len != 1 || !inventory.server.connected || inventory.server.busy
		|| profiles[0].server_id != inventory.server.server_id || profiles[0].runtime_id == '' {
		return error('connect the registered target host in Desktop: call targets_list')
	}
	profile := profiles[0]
	action := call.tool.all_after('application_release_')
	if action == 'prepare' {
		if args.rollback_from != '' && args.installation_id != '' {
			return error('rollback_from and installation_id are mutually exclusive')
		}
	} else {
		preview := inventory.server.mcp_release_preview
		kind := if action == 'rollback' { 'rollback' } else { 'release' }
		if preview.plan_id == '' || args.plan_id != preview.plan_id
			|| profile.id != preview.target_id || kind != preview.kind {
			return error('invalid_release_plan: prepare again')
		}
		if preview.phase == 'prepared' {
			if preview.expires_at <= time.now().unix() {
				return error('stale_release_plan: prepare again')
			}
			selection := s.selection()
			label := if kind == 'rollback' { '回滚' } else { '发布' }
			if !approve('${label} ${selection.application.label} → ${inventory.server.server.name} / ${profile.name}\n安装槽：${preview.component} · 版本：${preview.version}\n整个目标运行环境将短暂重启。\n操作 ID：${preview.plan_id}') {
				return error('release_denied')
			}
			s.check_management_binding(call)!
		}
	}
	select {
		inventory.worker.commands <- host.ServerCommand{
			action:      .mcp_release
			mcp_release: host.McpReleaseRequest{
				target_id:       profile.id
				server_id:       profile.server_id
				runtime_id:      profile.runtime_id
				component:       args.component
				installation_id: args.installation_id
				rollback_from:   args.rollback_from
				plan_id:         args.plan_id
				action:          action
				generation:      args.binding_revision
				deadline:        call.deadline
				access:          s.access
				reply:           call.reply
			}
		} {
		}
		else {
			return error('Desktop server worker busy')
		}
	}
}
