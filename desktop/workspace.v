module main

import host
import time
import application_logs
import ui2

// The selected location/registration owns lifecycle. Application selection is
// independent and never dispatches start/stop/select_project to the host.
enum WorkspacePage {
	environment
	applications
	relay
	configuration
	logs
}

fn (app &Workshop) workspace_data() host.RuntimeWorkspace {
	return if app.environment_id == '' {
		app.snapshot.workspace
	} else {
		app.remote_snapshot.workspace
	}
}

fn (app &Workshop) workspace_name() string {
	if app.environment_id != '' { return app.remote_name }
	return if app.projects.len > 0 { app.projects[app.selected].name } else { 'vhttpd' }
}

fn (mut app Workshop) reset_workspace() {
	app.workspace_page = .environment
	app.workspace_application = ''
	app.workspace_log_application = ''
	app.workspace_log_search = ''
	app.workspace_log_source = ''
	app.workspace_logs_follow = true
	app.workspace_logs_ready = false
	app.workspace_logs_offset = 0
	app.workspace_logs_text = ''
	app.workspace_logs_layout_pending = false
}

fn (mut app Workshop) handle_workspace_event(event string) bool {
 if event.starts_with('workspace_app_adopt_') {
  id := event.all_after('workspace_app_adopt_')
  for application in app.workspace_data().applications {
   if application.id != id {continue}
   if application.identity.app_id != '' {app.notice='此应用已有身份，请使用关联源码或更新应用。';return true}
   app.handle_component_event('component_open')
   app.component_name=application.id
   app.component_adopt_engines=application.engines.map(it.id)
   return true
  }
  return true
 }
 if event.starts_with('workspace_app_source_') {
  id := event.all_after('workspace_app_source_')
  for application in app.workspace_data().applications {
   if application.id != id {continue}
   files := ui2.open_file_dialog(title:ui_text('选择应用源码中的组件配置'))
   if files.len == 0 {return true}
   source := host.application_source_from_file(files[0]) or {app.notice=host.application_identity_hint(err.msg());return true}
   path := if app.environment_id != '' {app.remote_form().config_path} else {app.projects[app.selected].config_path}
   host.associate_application_source(app.environment_id,if app.environment_id != '' {app.remote_id} else {''},path,application,source) or {app.notice=host.application_identity_hint(err.msg());return true}
   app.notice='应用源码已关联，更新部署和本地接管将复用此关系。'
  }
  return true
 }
 if event.starts_with('workspace_app_update_') {
  id := event.all_after('workspace_app_update_')
  for application in app.workspace_data().applications {
   if application.id != id {continue}
   binding := app.workspace_application_binding(application) or {app.notice=host.application_identity_hint(err.msg());return true}
   if binding.installation_id == '' {app.notice='此应用尚未关联本地源码。';return true}
   source := host.validate_binding_source(binding) or {app.notice=host.application_identity_hint(err.msg());return true}
   app.handle_component_event('component_open')
   app.component_installation_id=binding.installation_id
   app.component_file=source.config_path
   app.component_name=binding.component
   return true
  }
  return true
 }

	if event.starts_with('workspace_tab_') || event.starts_with('workspace_go_') {
		app.workspace_page = match if event.starts_with('workspace_tab_') {
			event.all_after('workspace_tab_')
		} else {
			event.all_after('workspace_go_')
		} {
			'applications' { .applications }
			'relay' { .relay }
			'configuration' { .configuration }
			'logs' { .logs }
			else { .environment }
		}
		app.workspace_logs_ready = false
		return true
	}
	if event.starts_with('workspace_application_') {
		app.workspace_application = event.all_after('workspace_application_')
		app.workspace_page = .applications
		return true
	}
	if event.starts_with('workspace_app_logs_') {
		app.workspace_log_application = event.all_after('workspace_app_logs_')
		app.workspace_log_source = ''
		app.workspace_logs_text = ''
		app.workspace_page = .logs
		app.workspace_logs_ready = false
		app.workspace_logs_follow = true
		return true
	}
	match event {
		'workspace_relay_library' {
			app.open_relay_catalog()
		}
		'workspace_source_runtime', 'workspace_source_relay', 'workspace_source_stdout', 'workspace_source_application' {
			app.workspace_logs_text = ''
			app.workspace_log_source = event.all_after('workspace_source_')
			app.workspace_logs_ready = false
		}
		'workspace_app_back' { app.workspace_application = '' }
		'workspace_relay_logs' {
			app.workspace_logs_text = ''
			app.workspace_page = .logs
			app.workspace_log_source = 'relay'
			app.workspace_log_application = ''
			app.workspace_logs_ready = false
		}
		'workspace_logs_all' {
			app.workspace_logs_text = ''
			app.workspace_log_application = ''
			app.workspace_log_source = ''
			app.workspace_logs_ready = false
		}
		'workspace_logs_search' {
			app.workspace_logs_text = ''
			app.workspace_log_search = ui2.text(event)
			app.workspace_logs_ready = false
		}
		'workspace_logs_pause' { app.workspace_logs_follow = false }
		'workspace_logs_follow' {
			app.workspace_logs_follow = true
			app.workspace_logs_ready = false
		}
		else { return false }
	}
	return true
}

fn workspace_text(id string, text string, y f64, width f64, height f64) ui2.Element {
	field := ui2.text_area(id, text, ui2.rect(0, y, width, height), ui2.BoxStyle{ bg: workbench_sidebar, radius: 7 }, ui2.TextStyle{ size: 12, color: workbench_ink, font_family: workbench_detail_font() })
	return ui2.Element{ ...field, readonly: true }
}

fn runtime_workspace_view(mut app Workshop, width f64, height f64) []ui2.Element {
	remote := app.environment_id != ''
	data := app.workspace_data()
	mut rows := [
		label('workspace_location', app.environment_name() + '  /  vhttpd 运行环境', 0, 24, width, 12, workbench_muted),
		label('workspace_title', app.workspace_name(), 0, 60, width, 26, workbench_ink),
	]
	for i, item in ['environment', 'applications', 'relay', 'configuration', 'logs'] {
		title := ui_text_in('workspace-tab',['运行环境', '应用', 'Relay', '配置', '日志'][i])
		rows << choice_button('workspace_tab_' + item, title, f64(i) * 96, 110, 88, int(app.workspace_page) == i, true)
	}
	match app.workspace_page {
		.environment {
			ready := if remote {
				app.remote_snapshot.connected && app.remote_snapshot.instance.ready
			} else {
				app.snapshot.phase == .running
			}
			status := workspace_runtime_status(app)
			rows << state_notice('workspace_runtime_state', 'vhttpd · ' + status.title, status.detail, ui2.rect(0, 168, width, 102), status.tone)
			if remote {
				rows << button('remote_open', 'Admin UI ↗', 0, 290, 136, true, !app.remote_snapshot.busy)
				rows << button('remote_restart', if app.remote_snapshot.instance.startup_failed() { '修复后重试重启' } else { '重启运行环境' }, 148, 290, 150, false, !app.remote_snapshot.busy && app.remote_snapshot.instance.manual_restart && !app.remote_upgrade_running() && !app.deployment_running())
				rows << button('remote_check', '检查生效', 310, 290, 110, false, !app.remote_snapshot.busy)
				rows << button('remote_edit', '连接设置…', 0, 338, 136, false, !app.remote_snapshot.busy)
				rows << button('remote_disconnect', '断开管理连接', 148, 338, 150, false, true)
				if !ready {
					rows << button('remote_start', '启动运行环境', 310, 338, 150, false, app.can_start_remote_project())
				}
				rows << label('workspace_process', 'vhttpd ' + app.remote_snapshot.instance.version + ' · ' + app.remote_snapshot.instance.platform, 0, 400, width, 13, workbench_ink)
			} else {
				rows << button('start', '启动运行环境', 0, 290, 150, true, app.local_command_enabled('start'))
				rows << button(if app.snapshot.can_force { 'force' } else { 'stop' }, '停止运行环境', 162, 290, 150, false, app.local_command_enabled(if app.snapshot.can_force {
					'force'
				} else {
					'stop'
				}))
				rows << button('restart', if app.selected >= 0 && app.selected < app.projects.len && (app.config_statuses[app.projects[app.selected].config_path] or { host.ConfigStatus{} }).pending { '重启并检查生效' } else { '重启运行环境' }, 324, 290, 150, false, app.local_command_enabled('restart'))
				rows << button('admin', 'Admin UI ↗', 0, 338, 136, false, ready)
				rows << button('folder', '打开工程目录', 148, 338, 150, false, true)
				rows << label('workspace_process', if app.snapshot.pid > 0 {
					'PID ' + app.snapshot.pid.str() + ' · ' + app.snapshot.executor
				} else {
					'进程尚未启动'
				}, 0, 400, width, 13, workbench_ink)
			}
			rows << label('workspace_app_count', if data.applications_available() {
				if data.from_configuration { '已安装 ' + data.applications.len.str() + ' 个应用 · 本地配置，运行状态未确认' } else { '已加载 ' + data.applications.len.str() + ' 个应用 · ' + data.checked_at + ' 更新' }
			} else {
				if data.error != '' {
					data.error
				} else {
					'运行环境就绪后读取应用列表'
				}
			}, 0, 434, width, 13, workbench_muted)
			rows << button('workspace_go_applications', '查看承载的应用', 0, 478, 176, false, true)
			rows << label('workspace_lifecycle_hint', '重启会短暂影响本运行环境中的全部应用；断开远端管理连接不停止进程。', 0, 536, width, 12, workbench_muted)
			message := if remote {
				if app.remote_message != '' { app.remote_message } else { app.remote_snapshot.message }
			} else if app.notice != '' {
				app.notice
			} else {
				app.snapshot.message
			}
			rows << ui2.label('workspace_message', message, ui2.rect(0, 576, width, 72), ui2.TextStyle{ size: 12, color: workbench_muted, lines: 3 })
			if remote {
				rows << remote_access_notice(app, width, 672)
			}
		}
		.applications { rows << workspace_applications_view(app,data,width,height,remote) }

		.relay { rows << relay_overview_view(app,width,remote) }

		.configuration {
			rows << label('workspace_configuration_hint', '配置按所属对象组织；发布后在运行环境页检查和重启生效。', 0, 168, width, 12, workbench_muted)
			mut lines := [ui_text('运行环境配置'),
				ui_text('监听地址、端口、执行器、管理认证与公共资源。'), '', ui_text('应用配置'),
				ui_text('应用入口、请求管线及数据库/存储等资源绑定。'), '', ui_text('Relay 配置'),
				ui_text('通道端点、认证、自动重连和路由。'), '', ui_text('配置入口：')]
			lines << if remote {
				app.remote_form().config_path
			} else {
				app.projects[app.selected].config_path
			}
			rows << workspace_text('workspace_configuration_scopes', lines.join('\n'), 210, width, 280)
			if remote {
				rows << button('remote_open', '打开配置编辑器 ↗', 0, 514, 190, true, !app.remote_snapshot.busy)
				rows << button('remote_check', '检查生效', 202, 514, 120, false, !app.remote_snapshot.busy)
			} else {
				rows << button('edit_config', '打开入口配置', 0, 514, 160, true, true)
				rows << button('details', '查看配置组成', 172, 514, 140, false, true)
				rows << config_status_view(app, 0, 572, width)
			}
		}
		.logs { rows << workspace_logs_view(mut app, width, height) }
	}
	return rows
}

// Keep the application selector visible while inspecting a detail. Selection
// changes only the right pane and never changes the owning runtime/project.
fn (app &Workshop) selected_workspace_application(data host.RuntimeWorkspace) string {
 if data.applications.any(it.id == app.workspace_application) { return app.workspace_application }
 return if data.applications.len > 0 {data.applications[0].id} else {''}
}

fn workspace_applications_view(app &Workshop, data host.RuntimeWorkspace, width f64, height f64, remote bool) []ui2.Element {
 list_width := if width >= 620 {174.0} else {144.0}
 detail_x := list_width+24
 detail_width := width-detail_x
 pane_height := if height > 730 {height-238} else {492.0}
 selected := app.selected_workspace_application(data)
 mut rows := [label('workspace_apps_hint','应用共用当前 vhttpd 进程；选择应用查看监听、资源和日志。',0,168,if remote {width} else {width-166},12,workbench_muted)]
 if !remote {rows << button('takeover_open','本地接管…',width-152,160,152,false,app.projects.len>0)}
 mut items := []ui2.Element{}
 for i,application in data.applications {
  ports := application.listeners.filter(!it.control).map(it.protocol+' :'+it.port.str()).join(' · ')
  title := if application.label != '' {application.label} else {application.id}
  items << project_button('workspace_application_'+application.id,title,ports,ui2.rect(0,f64(i)*64,list_width-20,58),application.id==selected,true)
 }
 mut selector := [label('workspace_apps_count',if data.applications_available() {'已安装应用 · '+data.applications.len.str()} else {'已安装应用 · 未确认'},10,14,list_width-20,12,workbench_muted),
  ui2.scroll('workspace_app_list',ui2.rect(10,46,list_width-20,pane_height-154),workbench_sidebar,items),
  button('application_new_open','新建应用…',10,pane_height-94,list_width-20,true,!app.server_busy),
  button('component_open','安装已有应用…',10,pane_height-48,list_width-20,false,!app.server_busy)]
 rows << ui2.view('workspace_app_selector',ui2.rect(0,210,list_width,pane_height),ui2.BoxStyle{bg:workbench_sidebar,radius:8},selector)
 mut details := []ui2.Element{}
 if !data.applications_available() {
  details << state_notice('workspace_apps_unknown','应用列表尚未确认',if data.error!='' {data.error} else {'请先启动或连接运行环境。'},ui2.rect(0,0,detail_width,130),'info')
 } else if data.applications.len == 0 {
  details << label('workspace_apps_empty','当前运行环境未声明业务应用。',0,12,detail_width,13,workbench_muted)
 } else {
  for application in data.applications {
   if application.id != selected {continue}
   title := if application.label!='' {application.label} else {application.id}
   details << label('workspace_application_name',title,0,0,detail_width,22,workbench_ink)
   details << label('workspace_application_id','应用标识：'+application.id,0,42,detail_width,12,workbench_muted)
   binding := app.workspace_application_binding(application) or {host.ApplicationBinding{}}
   mut lines := [ui_text('所属运行环境：')+app.workspace_name()]
   if data.from_configuration {
    lines << ['',ui_text('来源：本地配置；运行状态未确认。')]
    if data.error != '' {lines << ui_text(data.error)}
   }
   if application.identity.app_id != '' {
    lines << ['',ui_text('应用身份：')+application.identity.app_id,ui_text('安装身份：')+application.identity.installation_id,ui_text('已部署版本：')+application.identity.version]
   }
   if application.identity_error != '' {lines << ['',ui_text('应用身份读取失败，请检查 app.json 和安装记录。')]}
   if binding.installation_id != '' {
    lines << [ui_text('本地源码：')+binding.source.workdir]
   } else {lines << ['',ui_text('此应用尚未关联本地源码。')]}
   lines << ['',ui_text('监听入口')]
   for l in application.listeners {if !l.control {lines << '${l.protocol} · ${l.host}:${l.port} · ${l.id}'}}
   lines << ['',ui_text('执行器')]
   for e in application.engines {lines << e.id+' · '+e.kind}
   lines << ['',ui_text('资源绑定')]
   for r in application.resources {lines << r.id+' · '+r.kind}
   if application.resources.len==0 {lines << ui_text('未声明资源绑定')}
   lines << ['',ui_text('请求管线')]
   for p in application.pipelines {lines << p.id+' · '+p.ingress+' → '+p.egress}
   details << workspace_text('workspace_application_details',lines.join('\n'),80,detail_width,pane_height-224)
   details << button(if application.identity.installation_id == '' {'workspace_app_adopt_'+application.id} else {'workspace_app_source_'+application.id},if application.identity.installation_id == '' {'迁移旧安装身份…'} else if binding.installation_id == '' {'关联本地源码…'} else {'更换源码位置…'},0,pane_height-126,detail_width,false,true)
   details << button('workspace_app_logs_'+application.id,'查看应用日志',0,pane_height-82,(detail_width-12)/2,true,true)
   details << button('workspace_app_update_'+application.id,'更新应用…',(detail_width+12)/2,pane_height-82,(detail_width-12)/2,false,binding.installation_id != '')
   details << ui2.label('workspace_application_scope','启停和升级由运行环境统一管理。',ui2.rect(0,pane_height-32,detail_width,32),ui2.TextStyle{size:11,color:workbench_muted,lines:2})
  }
 }
 rows << ui2.view('workspace_app_detail',ui2.rect(detail_x,210,detail_width,pane_height),ui2.BoxStyle{transparent:true},details)
 return rows
}

fn workspace_event_line(event host.RuntimeEvent) string {
	f := event.fields
	return time.unix(event.at_unix).utc_to_local().hhmmss() + '  ' + event.kind + '  ' + f['method'] + ' ' + f['path'] + '  ' + f['status'] +
		if f['listener_id'] != '' { '  listener=' + f['listener_id'] } else { '' } +
		if f['pipeline_id'] != '' { '  pipeline=' + f['pipeline_id'] } else { '' } +
		if f['duration_ms'] != '' { '  ' + f['duration_ms'] + ' ms' } else { '' } +
		if f['observation_id'] != '' { '  ' + f['observation_id'] } else { '' } +
		if f['message'] != '' { '  ' + f['message'] } else { '' } +
		if f['error'] != '' { '  ' + f['error'] } else { '' }
}

fn application_log_lines(data host.RuntimeWorkspace, app_id string, source string) []string {
	if error := data.application_logs_errors[app_id] { return [ui_text(error)] }
	batch := data.application_logs[app_id] or { return [ui_text('应用日志尚未读取；不会显示其他应用或进程输出。')] }
	mut lines := []string{}
	if batch.dropped > 0 { lines << ui_text('当前窗口未显示较早的 ${batch.dropped} 条记录，可查看本应用独立日志文件。') }
	for record in batch.records {
		if record.app_id != app_id { continue }
		if source == 'runtime' && record.source != 'request' { continue }
		if source == 'stdout' && record.source != 'console' { continue }
		if source == 'relay' && record.source != 'relay' { continue }
		lines << application_log_line(record)
	}
	if lines.len == 0 { lines << ui_text('本应用暂无此来源的日志。') }
	return lines
}

fn application_log_line(record application_logs.Record) string {
	return time.unix(record.at_unix).utc_to_local().hhmmss() + '  ['+record.app_id+'] '+record.level.to_upper()+' '+record.source+'  '+record.message +
		if record.request_id != '' {'\n    request='+record.request_id} else {''} +
		if record.trace_id != '' {'  trace='+record.trace_id} else {''} +
		if record.engine_id != '' {'  engine='+record.engine_id} else {''} +
		if record.pipeline_id != '' {'  pipeline='+record.pipeline_id} else {''}
}

fn workspace_logs_view(mut app Workshop, width f64, height f64) []ui2.Element {
	data := app.workspace_data()
	batch := data.application_logs[app.workspace_log_application] or { application_logs.Snapshot{} }
	file_visible := app.workspace_log_application != '' && batch.file != ''
	upgrade_visible := app.workspace_log_application != '' && data.application_logs_unsupported
	header_visible := file_visible || upgrade_visible
	mut lines := []string{}
	if app.workspace_log_application != '' {
		lines = application_log_lines(data,app.workspace_log_application,app.workspace_log_source)
	} else if app.workspace_log_source == 'application' {
		if all_batch := data.application_logs['*'] {
			lines = all_batch.records.map(application_log_line(it))
		} else { lines << ui_text('结构化应用日志接口不可用，请更新运行包或检查连接。') }
	} else if app.workspace_log_source == 'relay' {
		lines << app.relay_process_logs().split_into_lines()
		for e in data.relay.data.diagnostics.events { lines << relay_event_line(e) }
		for e in data.events {
			if data.applications.any(it.listeners.any(it.protocol == 'websocket') && it.owns_event(e)) { lines << workspace_event_line(e) }
		}
	} else if app.workspace_log_source == 'stdout' && app.environment_id == '' {
		lines = app.snapshot.logs.split_into_lines()
	} else {
		for e in data.events {
			if app.workspace_log_application != '' && !data.applications.any(it.id == app.workspace_log_application && it.owns_event(e)) {
				continue
			}
			lines << workspace_event_line(e)
		}
	}
	if app.workspace_log_search != '' {
		lines = lines.filter(it.to_lower().contains(app.workspace_log_search.to_lower()))
	}
	candidate_text := if lines.len > 0 {
		lines.join('\n')
	} else {
		ui_text('暂无匹配日志。应用日志按明确的应用/监听/管线标识筛选；无法归属的日志保留在运行环境日志中。')
	}
	// Pause when the reader scrolls upward. Updating log data must not steal
	// their reading position; Resume explicitly returns to the latest output.
	offset := ui2.scroll_offset('workspace_logs')
	if app.workspace_logs_ready && app.workspace_logs_follow && !app.workspace_logs_layout_pending && offset + 4 < app.workspace_logs_offset {
		app.workspace_logs_follow = false
	}
	app.workspace_logs_offset = offset
	text := if !app.workspace_logs_follow && app.workspace_logs_text != '' {
		app.workspace_logs_text
	} else {
		candidate_text
	}
	app.workspace_logs_layout_pending = app.workspace_logs_text != text
	app.workspace_logs_text = text
	if app.workspace_logs_follow { ui2.scroll_to_offset('workspace_logs', 1000000000) }
	app.workspace_logs_ready = true
	mut rows := [
		label('workspace_logs_scope', if app.workspace_log_application == '' {
			'运行环境日志 · ' + if app.workspace_log_source == 'relay' {
				'Relay'
			} else if app.workspace_log_source == 'application' {
				ui_text('全部应用结构化日志')
			} else if app.workspace_log_source == 'stdout' {
				if app.snapshot.log_filter != '' {
					ui_text('请求 ') + app.snapshot.log_filter
				} else {
					ui_text('本地进程输出')
				}
			} else {
				ui_text('全部应用运行事件')
			}
		} else {
			'应用日志 · ' + app.workspace_log_application
		}, 0, 168, width, 13, workbench_ink),
		input('workspace_logs_search', app.workspace_log_search, '搜索日志', 0, 204, width - 180, true),
		button(if app.workspace_logs_follow {
			'workspace_logs_pause'
		} else {
			'workspace_logs_follow'
		}, if app.workspace_logs_follow { '暂停跟随' } else { '回到底部并跟随' }, width - 168, 204, 168, !app.workspace_logs_follow, true),
		label('workspace_logs_status', if app.workspace_logs_follow {
			'自动滚动 · 向上翻阅可暂停'
		} else {
			'跟随已暂停 · 新日志继续接收'
		}, 0, 256, width - 154, 12, workbench_muted),
		button('workspace_logs_all', if app.workspace_log_application != '' { '环境日志' } else { '全部应用' }, width - 136, 248, 136, false, true),
		workspace_text('workspace_logs', text, if header_visible {380.0} else {344.0}, width, if height > 730 {
			height - if header_visible {424} else {388}
		} else {
			if header_visible {296.0} else {332.0}
		}),
		label('workspace_logs_source', if data.error != '' {
			data.error
		} else if app.workspace_log_application != '' && data.application_logs_errors[app.workspace_log_application] != '' {
			data.application_logs_errors[app.workspace_log_application]
		} else if app.workspace_log_application != '' && batch.storage_error != '' {
			'应用日志落盘失败：'+batch.storage_error
		} else if data.events_error != '' {
			data.events_error
		} else {
			if app.workspace_log_application != '' { '每应用显示最近 256 条；独立文件轮转保留，重启后加载历史。未归属输出仅在环境日志显示。' } else { '每 3 秒刷新。当前显示环境级运行事件；应用业务输出请进入应用日志。' }
		}, 0, if height > 730 { height - 28 } else { 696.0 }, width, 11, workbench_muted),
	]
	rows << choice_button('workspace_source_runtime', if app.workspace_log_application != '' { '请求记录' } else { '运行事件' }, 0, 296, 120, if app.workspace_log_application != '' {app.workspace_log_source == 'runtime'} else {app.workspace_log_source !in ['relay','stdout','application']}, true)
	rows << choice_button('workspace_source_relay', 'Relay', 132, 296, 100, app.workspace_log_source == 'relay', true)
	if app.environment_id == '' || app.workspace_log_application != '' {
		rows << choice_button('workspace_source_stdout', if app.workspace_log_application != '' { '应用输出' } else { '进程输出' }, 244, 296, 120, app.workspace_log_source == 'stdout', true)
	}
	if app.workspace_log_application != '' {
		rows << choice_button('workspace_source_application', '全部日志', 376, 296, 112, app.workspace_log_source in ['', 'application'], true)
	}

	if app.workspace_log_application == '' && !(app.workspace_log_source == 'stdout' && app.snapshot.log_filter != '') {
		rows << choice_button('workspace_source_application','应用汇总',376,296,112,app.workspace_log_source == 'application',true)
	}

	if file_visible {
		file_field := input('workspace_log_file',batch.file,'日志文件',0,336,width,true)
		rows << ui2.Element{...file_field,readonly:true,accessibility_label:'本应用日志文件'}
	}
	if upgrade_visible {
		rows << button('runtime','升级运行环境…',0,336,180,true,!app.server_busy && !app.runtime_busy)
	}

	if app.workspace_log_application == '' && app.workspace_log_source == 'stdout' && app.snapshot.log_filter != '' {
		rows << button('all_logs', '全部输出', 376, 296, width - 376, false, true)
	}
	return rows
}

fn (mut app Workshop) focus_request_logs() {
	app.set_environment('')
	app.show_remote = false
	app.show_servers = false
	app.show_runtime = false
	app.show_shared_relays = false
	app.show_deployment = false
	app.close_auxiliary_project_views()
	app.workspace_page = .logs
	app.workspace_log_source = 'stdout'
	app.workspace_log_application = ''
	app.workspace_log_search = ''
	app.workspace_logs_follow = true
	app.workspace_logs_ready = false
	app.workspace_logs_text = ''
}

fn (app &Workshop) relay_process_logs() string {
	if app.environment_id == '' {return if app.snapshot.logs == '' {ui_text('暂无本地进程输出。')} else {app.snapshot.logs}}
	if app.server_snapshot.server_id != app.environment_id || app.server_snapshot.relay_logs_project != app.remote_snapshot.profile_id {return ui_text('等待所选远端环境的进程日志…')}
	if !app.server_snapshot.connected {return ui_text('SSH 已断开，进程日志状态未确认。')}
	if app.server_snapshot.relay_logs_error != '' {return ui_text(app.server_snapshot.relay_logs_error)}
	return if app.server_snapshot.relay_logs == '' {ui_text('暂无进程输出。')} else {app.server_snapshot.relay_logs}
}

fn (app &Workshop) workspace_application_binding(application host.RuntimeApplication) !host.ApplicationBinding {
 path := if app.environment_id != '' {app.remote_form().config_path} else if app.selected >= 0 && app.selected < app.projects.len {app.projects[app.selected].config_path} else {''}
 if path == '' {return host.ApplicationBinding{}}
 return host.binding_for_application(app.environment_id,path,application)
}
