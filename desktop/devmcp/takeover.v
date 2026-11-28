module devmcp

import host
import time

fn (s &Service) queue_takeover(call RelayCall, worker host.Worker, inventory ManagementTargets, approve fn (string) bool) ! {
	s.check_management_binding(call)!
	a := call.args
	profiles := inventory.profiles.filter(it.id == a.target_id && it.server_id != '' && it.config_path != '')
	if profiles.len != 1 { return error('unknown_target: call targets_list') }
	action := call.tool.all_after('takeover_')
	if action == 'start' {
		p := inventory.local.mcp_takeover_preview
		if p.plan_id == '' || p.plan_id != a.plan_id || p.target_id != a.target_id {
			return error('invalid_takeover_plan: prepare again')
		}
		if p.expires_at <= time.now().unix() && !inventory.local.takeover_status.active {
			return error('stale_takeover_plan: prepare again')
		}
		if !approve('开启本地流量接管 → ${profiles[0].name} / ${p.component}\n认证应用：${p.auth_app_id}\n账号：${p.account}\n经 Relay ${p.relay_id} 发送到本机，租约最长 15 分钟。') {
			return error('takeover_denied')
		}
		s.check_management_binding(call)!
	}
	select {
		worker.mcp_takeover <- host.McpTakeoverRequest{
			action:          action
			target:          profiles[0]
			installation_id: a.installation_id
			auth_app_id:     a.auth_app_id
			account:         a.account
			plan_id:         a.plan_id
			lease_id:        a.lease_id
			generation:      a.binding_revision
			deadline:        call.deadline
			access:          s.access
			reply:           call.reply
		} {
		}
		else {
			return error('Desktop runtime worker busy')
		}
	}
}
