module main

import host
import ui2

// Project runtime data into service rows; never infer a healthy connection from
// a saved profile, or turn an unavailable runtime counter into zero.
struct RelayServiceRow {
	id string
	name string
	kind string
	detail string
	status string
	tone string
	metrics string
	application string
}

fn relay_service_rows(data host.RuntimeWorkspace) []RelayServiceRow {
	mut rows := []RelayServiceRow{}
	for item in data.relays {
		mut status := '状态未确认'
		mut tone := 'info'
		mut detail := if item.kind == 'hub' { '接收本地与远端 Agent 的连接' } else { '连接远端 Hub，断线后自动重连' }
		if data.relay.known && item.kind == 'hub' { status = '接收端就绪'; tone = 'good' }
		for agent in data.relay.data.agents {
			if agent.relay_id != item.id || !data.relay.known { continue }
			status = match agent.state {
				'registered', 'connected', 'ready' { '已连接' }
				'backoff' { '等待重连' }
				'connecting', 'registering' { '连接中' }
				else { agent.state }
			}
			tone = if agent.state in ['registered','connected','ready'] { 'good' } else if agent.state == 'backoff' { 'warning' } else { 'info' }
			if agent.attempt > 0 { detail = ui_text(detail) + ui_text(' · 尝试 ') + agent.attempt.str() + ui_text(' 次') }
			if agent.last_error != '' { tone = 'warning' }
		}
		rows << RelayServiceRow{id:'native_' + item.id, name:item.id, kind:ui_text('原生 Relay · ') + if item.kind == 'hub' { ui_text('Hub 接收端') } else { ui_text('Agent 主动连接') }, detail:detail, status:status, tone:tone, metrics:'请求通道与数据库等资源转发'}
	}
	mut seen := map[string]bool{}
	mut linked_apps := map[string]bool{}
	for application in data.applications {
		for listener in application.listeners {
			if listener.control || listener.protocol != 'websocket' || seen[listener.id] { continue }
			seen[listener.id] = true
			mut status := '状态未确认'
			mut metrics := '连接数尚未确认'
			mut tone := 'info'
			if data.websocket_known {
				for count in data.websocket_listeners {
					if listener.id !in count.listener_ids { continue }
					status = if count.active_connections > 0 { '有活动连接' } else { '等待连接' }
					tone = if count.active_connections > 0 { 'good' } else { 'info' }
					metrics = ui_text('${count.active_connections} 个连接') + ' · ' + ui_text('${count.active_rooms} 个房间')
				}
			}
			application_action := if linked_apps[application.id] { '' } else { application.id }
			linked_apps[application.id] = true
			rows << RelayServiceRow{id:'websocket_' + listener.id, name:if application.label != '' { application.label } else { application.id }, kind:'应用 WebSocket', detail:listener.host + ':' + listener.port.str() + ui_text(' · 监听 ') + listener.id, status:status, tone:tone, metrics:metrics, application:application_action}
		}
	}
	return rows
}

fn relay_status_badge(id string, title string, tone string, x f64, y f64, width f64) ui2.Element {
	bg, ink := state_colors(tone)
	return ui2.view(id, ui2.rect(x,y,width,26), ui2.BoxStyle{bg:bg,radius:13}, [
		ui2.label(id + '_text',title,ui2.rect(6,0,width-12,26),ui2.TextStyle{size:11,color:ink,align:.center}),
	])
}

fn relay_service_card(item RelayServiceRow, prefix string, y f64, width f64, compact bool) ui2.Element {
	id := prefix + '_' + item.id
	height := if compact { 88.0 } else { 112.0 }
	mut children := [
		ui2.label(id+'_name',item.name,ui2.rect(16,10,width-160,26),ui2.TextStyle{size:15,bold:true,color:workbench_ink}),
		relay_status_badge(id+'_state',item.status,item.tone,width-124,12,108),
		ui2.label(id+'_kind',item.kind,ui2.rect(16,39,width-32,18),ui2.TextStyle{size:11,color:workbench_muted}),
	]
	if !compact {
		children << ui2.label(id+'_detail',item.detail,ui2.rect(16,64,width-168,18),ui2.TextStyle{size:11,color:workbench_muted})
		children << ui2.label(id+'_metrics',item.metrics,ui2.rect(16,87,width-32,18),ui2.TextStyle{size:11,color:workbench_ink})
		if item.application != '' {
			children << button('workspace_application_'+item.application,'查看应用',width-112,57,96,false,true)
		}
	} else {
		children << label(id+'_metrics',item.metrics,16,57,width-32,11,workbench_ink)
	}
	return ui2.view(id,ui2.rect(0,y,width,height),ui2.BoxStyle{bg:workbench_paper,radius:8,border_color:workbench_line,border_left:1,border_right:1,border_top:1,border_bottom:1},children)
}

fn relay_metric(id string, title string, value string, hint string, frame ui2.Rect) ui2.Element {
	return ui2.view(id,frame,ui2.BoxStyle{bg:workbench_sidebar,radius:8},[
		label(id+'_title',title,14,9,frame.width-28,11,workbench_muted),
		label(id+'_value',value,14,32,frame.width-28,24,workbench_ink),
		label(id+'_hint',hint,14,72,frame.width-28,10,workbench_muted),
	])
}

fn relay_overview_view(app &Workshop, width f64, remote bool) []ui2.Element {
	data := app.workspace_data()
	live := data.relay
	mut rows := [label('relay_overview_title','连接与通道',0,164,width-158,18,workbench_ink),
		button('workspace_relay_library','管理连接库…',width-146,160,146,false,true),
		label('relay_overview_hint','运行中的服务与连接状态 · 自动刷新',0,194,width,12,workbench_muted)]
	columns := if width >= 620 { 4 } else { 2 }
	cell := (width - f64(columns-1)*12)/f64(columns)
	titles := ['原生 Relay 连接','应用 WebSocket','活动资源通道','失败请求']
	values := [if live.known {live.data.carrier_count.str()} else {'—'},if data.websocket_known {data.websocket_connections.str()} else {'—'},if live.known {live.data.open_channels.str()} else {'—'},if live.known {live.data.diagnostics.failed.str()} else {'—'}]
	hints := ['Agent 与 Hub 之间','全部应用的连接总数','完成后自动释放','原生 Relay · 本次运行']
	for i in 0..4 {
		rows << relay_metric('relay_metric_${i}',titles[i],values[i],hints[i],ui2.rect(f64(i%columns)*(cell+12),232+f64(i/columns)*112,cell,100))
	}
	mut y := 232.0 + f64(4/columns)*112 + 8
	rows << label('relay_services_title','环境中的服务',0,y,width-160,14,workbench_ink)
	rows << ui2.label('relay_services_updated',if data.checked_at != '' {'更新 '+data.checked_at} else {'等待运行时'},ui2.rect(width-160,y,160,25),ui2.TextStyle{size:11,color:workbench_muted,align:.right})
	y += 36
	services := relay_service_rows(data)
	if !data.known {
		rows << state_notice('relay_services_unknown','运行状态未确认',if data.error != '' {data.error} else {'请先启动或连接当前运行环境。'},ui2.rect(0,y,width,84),'info')
		y += 96
	} else if services.len == 0 {
		rows << state_notice('relay_services_empty','暂无中继服务','当前环境尚未声明原生 Relay 或 WebSocket 应用。',ui2.rect(0,y,width,84),'info')
		y += 96
	} else {
		for service in services {
			rows << relay_service_card(service,'relay_service',y,width,false)
			y += 124
		}
	}
	if data.websocket_error != '' || !live.known {
		message := [data.websocket_error,if !live.known {live.error} else {''}].filter(it != '').join(' · ')
		if message != '' {
			rows << ui2.label('relay_overview_error',message,ui2.rect(0,y,width,42),ui2.TextStyle{size:12,color:workbench_warning,lines:2})
			y += 50
		}
	}
	if !remote {
		rows << button('takeover_open','应用本地接管…',0,y,168,false,app.projects.len > 0)
		rows << label('relay_takeover_scope','按应用设置流量规则',182,y+4,width-182,11,workbench_muted)
		y += 54
	}
	rows << label('relay_recent_title','最近事件',0,y+5,width-154,14,workbench_ink)
	rows << button('workspace_relay_logs','完整日志 →',width-142,y,142,false,true)
	y += 46
	mut events := []host.RelayLiveEvent{}
	for i := live.data.diagnostics.events.len-1; i >= 0 && events.len < 6; i-- { events << live.data.diagnostics.events[i] }
	if events.len == 0 {
		rows << label('relay_recent_empty','暂无原生 Relay 事件；WebSocket 应用输出请查看完整日志。',0,y,width,12,workbench_muted)
	} else {
		for i,event in events {
			f := event.fields
			rows << ui2.view('relay_recent_${i}',ui2.rect(0,y,width,64),ui2.BoxStyle{bg:workbench_sidebar,radius:6},[
				label('relay_recent_${i}_summary',relay_event_line(event).all_before('\n'),12,7,width-24,12,workbench_ink),
				label('relay_recent_${i}_scope',f['relay_id'] + if f['route'] != '' {' · '+f['route']} else {''},12,34,width-24,11,workbench_muted),
			])
			y += 72
		}
	}
	return rows
}
