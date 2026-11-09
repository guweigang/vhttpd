module main

import host
import time
import ui2

struct RelayLogPane {
	name string
	value string
	offset f64
	height f64
}

fn relay_event_line(event host.RelayLiveEvent) string {
	f := event.fields
	clock := time.unix(event.at_ms / 1000).utc_to_local().hhmmss()
	kind := match event.kind {
		'relay.takeover.execute' { '本地执行' }
		'relay.takeover.forward' { '远端转交本地' }
		'relay.database.request' { '远端数据库' }
		'relay.takeover.control' { '接管控制' }
		else { event.kind }
	}
	return clock + '  ' + kind + '  ' + f['phase'] + '  ' + f['method'] + ' ' + f['path']
		+ f['operation'] + ' ' + f['resource'] + '  ' + f['status'] + '  '
		+ if f['duration_ms'] != '' { f['duration_ms'] + ' ms' } else { '' }
		+ if f['error_class'] != '' { '  错误：' + f['error_class'] } else { '' }
		+ if f['action'] != '' { '  ' + f['action'] } else { '' }
		+ if f['state'] != '' { '  ' + f['state'] } else { '' }
		+ '\n    relay=' + f['relay_id'] + '  route=' + f['route']
		+ if f['request_id'] != '' { '\n    request=' + f['request_id'] } else { '' }
		+ if f['channel_id'] != '' { '  channel=' + f['channel_id'] } else { '' }
}

fn relay_monitor_elements(app &Workshop, width f64, y f64, relay_id string) []ui2.Element {
	live := app.snapshot.relay_live
	mut connections := []string{}
	for agent in live.data.agents {
		if relay_id != '' && agent.relay_id != relay_id { continue }
		connections << agent.relay_id + ' · ' + agent.state + ui_text(' · 连接尝试 ') + agent.attempt.str()
			+ if agent.state == 'backoff' { ui_text(' · 等待自动重连') } else { '' }
	}
	mut requests := []string{}
	mut events := []string{}
	for i := live.data.diagnostics.events.len - 1; i >= 0; i-- {
		event := live.data.diagnostics.events[i]
		if relay_id != '' && event.fields['relay_id'] != relay_id { continue }
		if event.kind in ['relay.takeover.execute','relay.takeover.forward','relay.takeover.control'] {
			if requests.len < 60 { requests << relay_event_line(event) }
		} else if events.len < 100 { events << relay_event_line(event) }
	}
	mut channels := []string{}
	for channel in live.data.channels {
		channels << channel.id + ' · ' + channel.route + ' · ' + if channel.open { 'open' } else { 'closed' }
			+ ui_text(' · 缓冲 ') + channel.buffered_len.str() + ui_text(' · 返回 ') + channel.returned_len.str()
	}
	detail := if !live.known { if live.error != '' { ui_text(live.error) } else { ui_text('等待运行时诊断；尚未确认连接。') } }
		else { connections.join(' / ') + ui_text('\n活动通道 ') + live.data.open_channels.str() + ui_text(' · 待处理帧 ') + live.data.pending_frames.str()
			+ ui_text(' · 已完成 ') + live.data.diagnostics.completed.str() + ui_text(' · 失败 ') + live.data.diagnostics.failed.str()
			+ ui_text(' · 每 2 秒刷新 · ') + live.checked_at }
	mut result := [
		label('relay_monitor_title', '执行日志与 Relay 状态', 0, y, width - 160, 16, workbench_ink),
		button('takeover_monitor_all', '全部 Relay…', width - 144, y - 6, 144, false, true),
		ui2.label('relay_connection_state', detail, ui2.rect(0,y+38,width,68), ui2.TextStyle{size:12,color:workbench_muted,lines:3}),
		label('relay_requests_title', '接管请求 · 最近记录', 0, y+122, width, 13, workbench_ink),
		label('relay_transport_title', '通道与数据库事件 · 最近记录', 0, y+386, width, 13, workbench_ink),
	]
	for item in [
		RelayLogPane{name:'relay_request_logs',value:if requests.len > 0 { requests.join('\n\n') } else { ui_text('暂无接管记录；开启接管后，此处显示实际请求的执行位置、结果、耗时和请求 ID。') },offset:152.0,height:214.0},
		RelayLogPane{name:'relay_transport_logs',value:if events.len > 0 { events.join('\n\n') } else { ui_text('暂无 Relay 事件。只记录连接变化、资源操作与失败，不记录数据内容。') },offset:416.0,height:166.0},
		RelayLogPane{name:'relay_active_channels',value:if channels.len > 0 { channels.join('\n') } else { ui_text('当前没有活动通道；短请求完成后通道会正常释放，可在事件记录中查看历史。') },offset:598.0,height:52.0},
	] {
		field := ui2.text_area(item.name,item.value,ui2.rect(0,y+item.offset,width,item.height),ui2.BoxStyle{bg:workbench_sidebar,radius:7},ui2.TextStyle{size:11,color:workbench_ink,font_family:workbench_detail_font()})
		result << ui2.Element{...field,readonly:true}
	}
	return result
}

fn relay_monitor_view(app &Workshop, width f64) []ui2.Element {
	mut result := [label('relay_page_title','Relay 运行状态与日志',0,26,width-120,24,workbench_ink),
		button('takeover_monitor_back','返回接管',width-100,26,100,false,true)]
	active := app.snapshot.takeover_status.known && app.snapshot.takeover_status.active
	result << label('relay_takeover_summary', if active { '指定账号正在本地执行' } else if app.snapshot.takeover_status.known { '当前由远端执行' } else { '接管状态未确认，请返回接管页检查' },0,90,width-184,13,workbench_ink)
	if active { result << button('takeover_stop','结束本地接管',width-164,80,164,true,true) }
	result << relay_monitor_elements(app,width,152,'')
	result << ui2.label('relay_retention','保留最近 256 条事件，重新启动实例后清空。HTTP 状态表示请求处理结果，业务是否成功还需核对应用响应。',ui2.rect(0,830,width,54),ui2.TextStyle{size:12,color:workbench_muted,lines:3})
	return result
}
