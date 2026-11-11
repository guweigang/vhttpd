module main

import host
import ui2

fn (mut app Workshop) handle_takeover_event(event string) bool {
	if !event.starts_with('takeover_') { return false }
	match event {
		'takeover_runtime_start' {
			if app.environment_id == '' && app.local_command_enabled('start') {app.launch()}
		}
		'takeover_open' {
			if app.takeover_relay == '' && app.selected < app.projects.len {
				app.takeover_relay = host.project_takeover_relay(app.projects[app.selected].config_path)
			}
			app.show_takeover = true
		}
		'takeover_close' { app.show_takeover = false; app.show_relay_monitor = false }
		'takeover_monitor', 'takeover_monitor_all' { app.show_relay_monitor = true }
		'takeover_monitor_back' { app.show_relay_monitor = false }
		'takeover_relay' { app.takeover_relay = ui2.text(event) }
		'takeover_app_id' { app.takeover_app_id = ui2.text(event) }
		'takeover_account' { app.takeover_account = ui2.text(event) }
        'takeover_binding' {
            app.takeover_binding_id = ''
            for target in app.takeover_targets() {
                if target.label == ui2.text(event) {app.takeover_binding_id=target.key()}
            }
        }
		'takeover_start', 'takeover_stop', 'takeover_status', 'takeover_prepare' {
			action := match event {
				'takeover_start' { host.Action.takeover_start }
				'takeover_stop' { host.Action.takeover_stop }
				'takeover_prepare' { host.Action.takeover_prepare }
				else { host.Action.takeover_status }
			}
			target := app.selected_takeover_target()
            if event == 'takeover_start' && app.takeover_requires_binding() && target.binding.installation_id == '' {app.notice='请先关联远端安装并选择接管应用。';return true}
            next := app.sequence + 1
			select {
				app.worker.commands <- host.Command{ action: action, sequence: next, takeover: host.TakeoverSelection{ application_id:target.binding.app_id,installation_id:target.binding.installation_id,component:target.binding.component,local_engine_id:target.local_engine, relay_id: app.takeover_relay.trim_space(), app_id: app.takeover_app_id.trim_space(), accounts: [app.takeover_account.trim_space()] } } {
					app.sequence = next
				}
				else {
					app.notice = '工作台正在处理操作，请稍后重试。'
				}
			}
		}
		else {}
	}
	return true
}

fn takeover_view(app &Workshop, width f64) []ui2.Element {
	status := if app.snapshot.takeover_relay_id == app.takeover_relay.trim_space() {
		app.snapshot.takeover_status
	} else {
		host.TakeoverStatus{}
	}
	ready := app.snapshot.phase == .running
	can_start := ready && status.known && !status.active && status.local_in_flight == 0
		&& app.takeover_app_id.trim_space() != '' && app.takeover_account.trim_space() != ''
        && (!app.takeover_requires_binding() || app.selected_takeover_target().binding.installation_id != '')
	mut elements := [
		label('takeover_title', '远端调试 / 本地接管', 0, 26, width - 120, 24, workbench_colors.ink),
		button('takeover_close', '返回应用', width - 100, 26, 100, false, true),
		ui2.label('takeover_intro', '客户端继续访问远端地址。指定账号的请求经 Relay 在本机执行，数据库仍由远端提供。', ui2.rect(0, 82, width, 48), ui2.TextStyle{ size: 12, color: workbench_colors.muted, lines: 2 }),
		state_notice('takeover_state', if !ready {
			'本地运行环境未启动'
		} else if !status.known {
			'接管状态未确认'
		} else if status.active {
			'指定账号正在本地执行'
		} else {
			'远端执行'
		}, if !ready {
			'项目中的 Relay 配置仍保留。启动本地运行环境后，再检查连接并开启指定账号接管。'
		} else if !status.known {
			'选择 Relay 后检查连接状态。'
		} else if status.active {
			status.app_id + ' · ' + status.accounts.join(', ') + ui_text('。最长 15 分钟；结束、到期或断线后，新请求恢复远端执行。')
		} else {
			ui_text('后续请求由远端执行。') + if status.local_in_flight > 0 { ui_text('本地正在收尾，请稍后再开启。') } else { '' } + ui_text('上次检查 ') + status.checked_at
		}, ui2.rect(0, 148, width, 96), if status.known && status.active { 'good' } else { 'info' }),
		label('takeover_relay_label', 'Relay 连接', 0, 270, width, 12, workbench_colors.ink),
		input('takeover_relay', app.takeover_relay, '项目中已配置的 Relay ID', 0, 294, width - 156, !status.active),
		button('takeover_status', '检查连接', width - 140, 294, 140, false, ready),
		label('takeover_app_id_label', '认证应用标识', 0, 354, width, 12, workbench_colors.ink),
		input('takeover_app_id', app.takeover_app_id, '远端认证使用的应用标识', 0, 378, width, !status.active),
		label('takeover_account_label', '账号标识', 0, 438, width, 12, workbench_colors.ink),
		input('takeover_account', app.takeover_account, '远端认证确认的用户标识', 0, 462, width, !status.active),
		ui2.label('takeover_identity_hint', '两项标识须与应用认证适配器提供的身份一致，仅接管该账号的请求。', ui2.rect(0, 512, width, 42), ui2.TextStyle{ size: 12, color: workbench_colors.muted, lines: 2 }),
		button(if status.active { 'takeover_stop' } else { 'takeover_start' }, if status.active { '结束本地接管' } else { '开启本地接管' }, 0, 574, 164, true, if status.active { ready } else { can_start }),
		button('takeover_monitor', '实时日志…', 180, 574, 144, false, ready),
		ui2.label('takeover_rules', '接管期间会读写远端真实数据库。已转交本地的请求遇到超时或断线会明确失败，不会再次在远端执行。', ui2.rect(0, 632, width, 64), ui2.TextStyle{ size: 12, color: workbench_colors.muted, lines: 3 }),
	]
	elements << relay_monitor_elements(app,width,724,app.takeover_relay.trim_space())
	elements << [
		label('takeover_setup_title', '首次配置', 0, 1390, width, 13, workbench_colors.ink),
		ui2.label('takeover_setup', '需要项目配置接收入口、远端授权和应用认证适配器。配置完成后，开启和结束接管无需重启。', ui2.rect(0, 1420, width, 56), ui2.TextStyle{ size: 12, color: workbench_colors.muted, lines: 3 }),
		button('takeover_prepare', '配置接收入口…', 0, 1492, 164, false, ready && !status.active),
		ui2.label('takeover_message', app.snapshot.message, ui2.rect(0, 1550, width, 80), ui2.TextStyle{ size: 12, color: workbench_colors.ink, lines: 4 }),
	]
targets := app.takeover_targets()
    if targets.len > 0 || app.takeover_requires_binding() {
        mut shifted := []ui2.Element{}
        for element in elements {
            shifted << if element.frame.y >= 148 {ui2.Element{...element,frame:ui2.Rect{...element.frame,y:element.frame.y+90}}} else {element}
        }
        selected := app.selected_takeover_target()
        title := if selected.binding.installation_id == '' {ui_text('请选择已部署应用。')} else {selected.label}
        if targets.len == 0 {
            shifted << state_notice('takeover_binding_missing','尚未关联远端应用','请先在远端应用详情中关联同一份源码，再配置本地接收入口。应用 UUID 和目标安装 UUID 一致后才能接管。',ui2.rect(0,142,width,78),'warning')
        } else {
        shifted << label('takeover_binding_label','已关联的远端应用',0,144,width,12,workbench_colors.muted)
        mut choices := if selected.binding.installation_id == '' {[title]} else {[]string{}}
        choices << targets.map(it.label)
        shifted << form_select('takeover_binding',title,choices,ui2.rect(0,168,width,36),!status.active)
        }
        elements=shifted.clone()
    }
	if !ready {
		mut shifted := []ui2.Element{}
		for element in elements {
			shifted << if element.frame.y >= (if targets.len > 0 || app.takeover_requires_binding() {238.0} else {148.0}) {
				ui2.Element{...element,frame:ui2.Rect{...element.frame,y:element.frame.y+54}}
			} else {element}
		}
		shifted << button('takeover_runtime_start',if app.snapshot.phase == .starting {'正在启动…'} else {'启动本地运行环境'},0,if targets.len > 0 || app.takeover_requires_binding() {238.0} else {148.0},188,true,app.environment_id == '' && app.local_command_enabled('start'))
		return shifted
	}
	return elements
}

fn (app &Workshop) takeover_targets() []host.TakeoverApplicationTarget {
 if app.selected < 0 || app.selected >= app.projects.len {return []host.TakeoverApplicationTarget{}}
 return host.takeover_application_targets(app.projects[app.selected].config_path) or {[]host.TakeoverApplicationTarget{}}
}

fn (app &Workshop) selected_takeover_target() host.TakeoverApplicationTarget {
 targets := app.takeover_targets()
 for target in targets {if target.key() == app.takeover_binding_id {return target}}
 return if targets.len == 1 {targets[0]} else {host.TakeoverApplicationTarget{}}
}

fn (app &Workshop) takeover_requires_binding() bool {
 if app.selected < 0 || app.selected >= app.projects.len {return false}
 return host.project_uses_application_meta(app.projects[app.selected].config_path)
}
