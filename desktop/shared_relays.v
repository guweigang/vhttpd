module main

import host
import net.urllib
import ui2

fn (app &Workshop) shared_form() host.SharedRelay {
	return host.SharedRelay{ protocol: app.shared_protocol, id: app.shared_id, relay_id: if app.shared_protocol == 'websocket' {''} else {app.shared_remote_id}, name: app.shared_name.trim_space(), url: app.shared_url.trim_space(), token: app.shared_token }
}

fn (app &Workshop) shared_saved() bool {
	return app.catalog_items().any(it == app.shared_form())
}

fn (mut app Workshop) handle_shared_relay_event(event string) bool {
	if event == 'shared_relays' {
		app.open_relay_catalog()
		return true
	}
	if event == 'shared_close' {
		app.show_shared_relays = false
		app.show_remote = app.environment_id != ''
		app.workspace_page = .relay
		return true
	}
	if !event.starts_with('shared_') { return false }
	if app.shared_testing { return true }
	match event {
		'shared_detail_connection' { app.shared_detail_tab = 'connection' }
		'shared_detail_history' { app.shared_detail_tab = 'history' }
		'shared_detail_binding' { app.shared_detail_tab = 'binding' }
		'shared_refresh' { if app.environment_id != '' {app.catalog_command(.relay_load)} else {app.shared_relays = host.load_shared_relays() or {app.shared_message = '本机连接库读取失败。'; return true}} }
		'shared_protocol_native' { app.shared_protocol = 'vhttpd'; app.shared_message = '原生 Relay：测试 WebSocket 和 Relay 认证。' }
		'shared_protocol_websocket' { app.shared_protocol = 'websocket'; app.shared_message = '应用 WebSocket：只测试协议升级，应用认证需另行验证。' }
		'shared_db_local' { app.shared_db_local = ui2.text(event) }
		'shared_db_remote' { app.shared_db_remote = ui2.text(event) }
		'shared_db_route' { app.shared_db_route = ui2.text(event) }
		'shared_db_use' {
			if app.environment_id != '' || !app.shared_form().is_native() || app.projects.len == 0 || app.snapshot.phase != .running || !app.shared_saved() {
				app.shared_message = '请保存连接并启动所选本地项目。'
				return true
			}
			next := app.sequence + 1
			select {
				app.worker.commands <- host.Command{action: .use_relay_database, sequence: next, shared_relay: app.shared_form(), relay_database: host.RelayDatabaseSelection{local_resource: app.shared_db_local.trim_space(), remote_resource: app.shared_db_remote.trim_space(), route: app.shared_db_route.trim_space()}} {
					app.sequence = next
					app.shared_use_pending = true
					app.shared_message = '正在生成远端数据库绑定草稿…'
				}
				else { app.shared_message = '工作台正在处理操作，请稍后重试。' }
			}
		}
		'shared_new' {
			app.shared_detail_tab = 'connection'
			app.shared_id = host.new_shared_relay_id() or {
				app.shared_message = '无法创建连接编号。'
				return true
			}
			app.shared_protocol = 'vhttpd'
			app.shared_remote_id = 'hub'
			app.shared_name = ''
			app.shared_url = ''
			app.shared_token = ''
			app.shared_message = '新建连接；Token 保存在所选位置的私有连接库中。'
		}
		'shared_name' {
			app.shared_name = ui2.text(event)
			app.shared_message = '连接已修改，保存或测试后再使用。'
		}
		'shared_url' {
			app.shared_url = ui2.text(event)
			app.shared_message = '地址已修改，原测试结果不再有效。'
		}
		'shared_remote_id' {
			app.shared_remote_id = ui2.text(event)
			app.shared_message = 'Relay ID 已修改，请重新测试。'
		}
		'shared_token' {
			app.shared_token = ui2.text(event)
			app.shared_message = '认证已修改，原测试结果不再有效。'
		}
		'shared_save' {
			r := app.shared_form()
			r.validate() or {
				app.shared_message = err.msg()
				return true
			}
			if app.environment_id != '' { app.catalog_command(.relay_save); return true }
			mut items := app.shared_relays.filter(it.id != r.id)
			items << r
			host.save_shared_relays(items) or {
				app.shared_message = '保存失败，连接库未更新。'
				return true
			}
			app.shared_relays = items
			app.shared_message = '连接已保存；已有项目保持原配置。可点击测试连接。'
		}
		'shared_delete' {
			if !ui_confirm('删除共享连接', '仅从连接库删除；不会修改或删除任何项目中的 Relay 配置。') {
				return true
			}
			if app.environment_id != '' { app.catalog_command(.relay_delete); return true }
			items := app.shared_relays.filter(it.id != app.shared_id)
			host.save_shared_relays(items) or {
				app.shared_message = '删除失败，连接库未更新。'
				return true
			}
			app.shared_relays = items
			app.shared_id = ''
			app.shared_protocol = 'vhttpd'
			app.shared_remote_id = 'hub'
			app.shared_name = ''
			app.shared_url = ''
			app.shared_token = ''
			app.shared_message = '共享连接已删除，项目配置未修改。'
		}
		'shared_test' {
			r := app.shared_form()
			r.validate() or {
				app.shared_message = err.msg()
				return true
			}
			app.start_shared_relay_test(r)
		}
		'shared_use' {
			if app.environment_id != '' || !app.shared_form().is_native() || app.projects.len == 0 || app.snapshot.phase != .running || !app.shared_saved() {
				app.shared_message = '请保存连接并启动所选项目。'
				return true
			}
			next := app.sequence + 1
			select {
				app.worker.commands <- host.Command{ action: .use_shared_relay, sequence: next, shared_relay: app.shared_form() } {
					app.sequence = next
					app.shared_use_pending = true
					app.shared_message = '正在打开项目的独立草稿；请在 Admin UI 完成绑定、校验与发布。'
				}
				else {
					app.shared_message = '工作台正在处理操作，请稍后重试。'
				}
			}
		}
		else {
			if event.starts_with('shared_pick_') {
				app.shared_detail_tab = 'connection'
				id := event.all_after('shared_pick_')
				for r in app.catalog_items() {
					if r.id == id {
						app.shared_protocol = if r.is_native() {'vhttpd'} else {'websocket'}
						app.shared_id = r.id
						app.shared_remote_id = r.relay_id
						app.shared_name = r.name
						app.shared_url = r.url
						app.shared_token = r.token
						app.shared_message = app.shared_status[shared_status_key(app.environment_id, r)] or { '本次会话尚未测试；保存记录不代表正在连接。' }
						break
					}
				}
			}
		}
	}
	return true
}

fn test_shared_connection(r host.SharedRelay, results chan host.RelayProbeResult) {
	results <- host.probe_shared_relay(r)
}

fn shared_relay_endpoint(value string) string {
	u := urllib.parse(value) or { return '地址待填写' }
	return u.host
}

fn shared_connection_row(relay host.SharedRelay, selected bool, width f64, y f64, enabled bool, status string) ui2.Element {
	id := 'shared_pick_' + relay.id
	mut rows := [
		ui2.label(id+'_name',relay.name,ui2.rect(12,8,width-24,24),ui2.TextStyle{size:13,bold:true,color:workbench_ink}),
		ui2.label(id+'_kind',if relay.is_native() {'原生 Relay'} else {'应用 WebSocket'},ui2.rect(12,34,width-24,18),ui2.TextStyle{size:10,color:workbench_muted}),
		ui2.label(id+'_host',shared_relay_endpoint(relay.url),ui2.rect(12,54,width-24,18),ui2.TextStyle{size:10,color:workbench_muted}),
		ui2.label(id+'_probe',status,ui2.rect(12,76,width-24,38),ui2.TextStyle{size:10,color:workbench_muted,lines:2}),
	]
	hit := ui2.button(id,'',ui2.rect(0,0,width,120),ui2.BoxStyle{transparent:true},ui2.TextStyle{})
	rows << ui2.Element{...hit,enabled:enabled,accessibility_label:relay.name + ' · ' + if relay.is_native() {ui_text('原生 Relay')} else {ui_text('应用 WebSocket')}}
	return ui2.view(id+'_row',ui2.rect(0,y,width,120),ui2.BoxStyle{bg:if selected {workbench_soft_accent} else {workbench_sidebar},radius:7,border_color:workbench_accent,border_left:if selected {3.0} else {0.0}},rows)
}

fn shared_relays_view(app &Workshop, width f64) []ui2.Element {
	items := app.catalog_items()
	mut rows := [
		label('shared_title','已保存的 Relay 连接',0,26,width-148,24,workbench_ink),
		label('shared_intro',ui_text('测试发起主机：') + app.shared_probe_host() + ui_text(' · 主机内共享，修改不会自动更新运行环境配置'),0,64,width,12,workbench_muted),
		button('shared_close','返回 Relay',width-136,26,136,false,true),
		label('shared_connection_count','已保存连接 · '+items.len.str(),0,104,width-140,14,workbench_ink),
		button('shared_new','+ 新建连接',width-120,104,120,true,!app.shared_testing),
	]
	list_width := if width >= 620 {190.0} else {144.0}
	x := list_width+24
	mut list := [label('shared_list_title','列表',12,10,list_width-88,12,workbench_muted),
		button('shared_refresh','刷新',list_width-68,6,56,false,!app.shared_catalog_pending && !app.shared_testing)]
	mut connections := []ui2.Element{}
	for i,relay in items {
		status := if app.shared_testing && app.shared_test_scope == app.environment_id && app.shared_test_id == relay.id { '正在测试…' } else { app.shared_status[shared_status_key(app.environment_id, relay)] or { '本次会话尚未测试' } }
		connections << shared_connection_row(relay,app.shared_id==relay.id,list_width-16,f64(i*128),!app.shared_testing,status)
	}
	if items.len == 0 {
		connections << ui2.label('shared_list_empty',if !app.catalog_ready() {'连接服务器后刷新'} else {'还没有保存的连接'},ui2.rect(8,12,list_width-32,66),ui2.TextStyle{size:12,color:workbench_muted,lines:3})
	}
	list << ui2.scroll('shared_list',ui2.rect(8,50,list_width-16,396),workbench_sidebar,connections)
	list << ui2.label('shared_list_scope','仅保存连接参数。运行状态请返回 Relay 查看。',ui2.rect(12,458,list_width-24,48),ui2.TextStyle{size:10,color:workbench_muted,lines:3})
	rows << ui2.view('shared_selector',ui2.rect(0,164,list_width,522),ui2.BoxStyle{bg:workbench_sidebar,radius:8},list)
	body := shared_relay_detail(app,width-x)
	rows << ui2.view('shared_detail',ui2.rect(x,164,width-x,elements_height(body)),ui2.BoxStyle{transparent:true},body)
	return rows
}

fn shared_relay_detail(app &Workshop, width f64) []ui2.Element {
	if app.shared_id == '' {
		return [label('shared_empty','选择或新建连接',0,18,width,20,workbench_ink),
			ui2.label('shared_empty_help','从左侧选择连接进行编辑，也可以添加原生 Relay 或应用 WebSocket。',ui2.rect(0,66,width,74),ui2.TextStyle{size:13,color:workbench_muted,lines:3}),
			ui2.label('shared_empty_status',if app.shared_message != '' {app.shared_message} else {'运行中的连接与通道状态请返回 Relay 查看。'},ui2.rect(0,154,width,78),ui2.TextStyle{size:12,color:workbench_muted,lines:4})]
	}
	native := app.shared_form().is_native()
	binding := native && app.environment_id == ''
	section := if app.shared_detail_tab == 'binding' && !binding {'connection'} else {app.shared_detail_tab}
	mut rows := [
		label('shared_detail_title',if app.shared_name.trim_space() != '' {app.shared_name} else {ui_text('新建连接')},0,0,width-88,18,workbench_ink),
		relay_status_badge('shared_saved_badge',if app.shared_saved() {'已保存'} else {'未保存'},'info',width-80,0,80),
		button('shared_save','保存',0,42,84,!app.shared_saved(),!app.shared_testing && !app.shared_catalog_pending && app.catalog_ready()),
		button('shared_test',if app.shared_testing {'测试中…'} else {'测试连接'},96,42,108,false,app.shared_probe_available()),
		button('shared_delete','移除…',width-72,42,72,false,!app.shared_testing && !app.shared_catalog_pending && app.shared_saved()),
	]
	tabs := if binding {['connection','history','binding']} else {['connection','history']}
	tab_width := (width-f64(tabs.len-1)*8)/f64(tabs.len)
	for i,tab in tabs {
		title := match tab {'history' {'测试记录'} 'binding' {'项目绑定'} else {'连接设置'}}
		rows << choice_button('shared_detail_'+tab,title,f64(i)*(tab_width+8),94,tab_width,section==tab,!app.shared_testing)
	}
	if section == 'history' {
		rows << state_notice('shared_notice',if app.shared_testing {'正在测试'} else {'最近操作'},if app.shared_message != '' {app.shared_message} else {'尚未测试连接。'},ui2.rect(0,146,width,104),'info')
		logs := app.shared_probe_logs.filter(it.starts_with(app.environment_id+':'+app.shared_id+' · ')).join('\n')
		rows << label('shared_probe_title','本次会话的测试记录',0,272,width,13,workbench_ink)
		rows << workspace_text('shared_probe_history',if logs != '' {logs} else {ui_text('暂无测试记录。点击上方“测试连接”进行探测。')},306,width,190)
		rows << ui2.label('shared_probe_scope',app.shared_probe_description(),ui2.rect(0,514,width,66),ui2.TextStyle{size:11,color:workbench_muted,lines:3})
		return rows
	}
	if section == 'binding' {rows << shared_binding_view(app,width,146);return rows}
	rows << choice_button('shared_protocol_native','原生 Relay',0,146,(width-8)/2,native,!app.shared_testing)
	rows << choice_button('shared_protocol_websocket','WebSocket',(width+8)/2,146,(width-8)/2,!native,!app.shared_testing)
	rows << label('shared_name_label','连接名称',0,192,width,11,workbench_muted)
	rows << input('shared_name',app.shared_name,'例如：生产 Hub',0,214,width,!app.shared_testing)
	rows << label('shared_url_label','地址 · ws:// 或 wss://',0,266,width,11,workbench_muted)
	rows << input('shared_url',app.shared_url,'wss://example.com/relay',0,288,width,!app.shared_testing)
	mut y := 340.0
	if native {
		rows << label('shared_remote_label','远端 Relay ID',0,y,width,11,workbench_muted)
		rows << input('shared_remote_id',app.shared_remote_id,'与远端 Hub 保持一致',0,y+22,width,!app.shared_testing)
		y += 74
	}
	rows << label('shared_token_label',if native {'Relay Token · 可选'} else {'HTTP Bearer Token · 可选'},0,y,width,11,workbench_muted)
	rows << ui2.Element{...input('shared_token',app.shared_token,'保存在当前私有连接库',0,y+22,width,!app.shared_testing),secure:true}
	rows << ui2.label('shared_auth_hint',if native {'验证 WebSocket 握手及 Relay 认证。'} else {'仅验证 WebSocket 握手；应用登录与权限需另行验证。'},ui2.rect(0,y+70,width,44),ui2.TextStyle{size:11,color:workbench_muted,lines:2})
	rows << ui2.label('shared_notice',if app.shared_testing {ui_text('正在测试 · ') + app.shared_test_host} else if app.environment_id != '' && !app.shared_probe_available() {app.shared_probe_description()} else if app.shared_message != '' {app.shared_message} else {app.shared_probe_description()},ui2.rect(0,y+122,width,70),ui2.TextStyle{size:12,color:workbench_ink,lines:4})
	return rows
}

fn shared_binding_view(app &Workshop, width f64, top f64) []ui2.Element {
	project := if app.projects.len > 0 {app.projects[app.selected].name} else {'请先选择本地项目'}
	mut rows := [label('shared_project_label','目标运行环境 · '+project,0,top,width,13,workbench_ink),
		button('shared_use','生成 Relay 配置草稿 ↗',0,top+36,width,false,!app.shared_testing && app.shared_saved() && app.projects.len>0 && app.snapshot.phase==.running),
		ui2.label('shared_use_hint','先保存连接并启动项目；生成草稿后在 Admin UI 校验、发布。',ui2.rect(0,top+84,width,52),ui2.TextStyle{size:11,color:workbench_muted,lines:3}),
		label('shared_db_title','绑定远端数据库',0,top+158,width,16,workbench_ink)]
	for i,key in ['local','remote','route'] {
		y := top+202+f64(i*74)
		title := ['本地数据库资源名','远端数据库资源','远端导出 Pipeline ID'][i]
		value := [app.shared_db_local,app.shared_db_remote,app.shared_db_route][i]
		placeholder := ['wechat','db/wechat','resource/database'][i]
		rows << label('shared_db_'+key+'_label',title,0,y,width,11,workbench_muted)
		rows << input('shared_db_'+key,value,placeholder,0,y+22,width,!app.shared_testing)
	}
	rows << button('shared_db_use','生成数据库绑定草稿 ↗',0,top+434,width,false,!app.shared_testing && app.shared_saved() && app.projects.len>0 && app.snapshot.phase==.running)
	rows << ui2.label('shared_db_hint','远端需先配置授权导出；发布并重启后生效。',ui2.rect(0,top+482,width,48),ui2.TextStyle{size:11,color:workbench_muted,lines:2})
	return rows
}
