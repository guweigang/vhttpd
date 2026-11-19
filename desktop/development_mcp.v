module main

import devmcp
import host
import os
import ui2

struct DevelopmentConnectionResult {
	service     &devmcp.Service = unsafe { nil }
	project     host.Project
	application string
	error       string
}

fn development_connect(worker host.Worker, existing &devmcp.Service, project host.Project, application string, directory string, binary string, results chan DevelopmentConnectionResult) {
	mut service := existing
	if isnil(service) {
		service = if application == '' {
			devmcp.start_workspace(worker, project, binary, desktop_version) or {
				results <- DevelopmentConnectionResult{ error: err.msg() }
				return
			}
		} else {
			devmcp.start_managed_application(worker, project, application, binary, desktop_version, directory) or {
				results <- DevelopmentConnectionResult{ error: err.msg() }
				return
			}
		}
	} else {
		service.select_application(worker, project, application, binary, directory) or {
			results <- DevelopmentConnectionResult{ error: err.msg() }
			return
		}
	}
	results <- DevelopmentConnectionResult{ service: service, project: project, application: application }
}

fn development_source_connect(worker host.Worker, directory string, binary string, results chan DevelopmentConnectionResult) {
	service := devmcp.start_source_workspace(worker, directory, binary, desktop_version) or {
		results <- DevelopmentConnectionResult{ error: err.msg() }
		return
	}
	selection := service.selection()
	results <- DevelopmentConnectionResult{ service: service, project: selection.project, application: selection.application.id }
}

fn (mut app Workshop) poll_development() {
	if !app.development_pending && !isnil(app.development_service) && app.development_service.poll_relay() {
		app.development_message = 'Relay 授权已过期或 Agent 已退出，发布已关闭。'
		ui2.refresh()
	}
	if !app.development_pending && !isnil(app.development_service) {
		selection := app.development_service.selection()
		if selection.generation != app.development_runtime_generation {
			app.development_runtime_generation = selection.generation
			if selection.source_workspace {
				app.development_service.revoke_relay()
				app.development_project = selection.project
				app.development_application = selection.application.id
				app.development_message = '源码工作区直接使用原目录；无需安装。绑定切换后请重新读取 context_get。'
			}
			if selection.binary != '' && selection.binary != app.binary && !app.runtime_busy {
				app.development_service.revoke_relay()
				app.inspect_binary(selection.binary, false)
			}
		}
		targets := app.development_relay_choices.filter(it.id == app.development_relay_id)
		target := if targets.len == 1 { targets[0] } else { host.SharedRelay{} }
		if app.development_service.poll_relay_calls(app.worker, desktop_version, target, app.development_relay_url.trim_space(), fn (message string) bool {
			return ui_confirm('确认 Desktop MCP 操作', message)
		}, devmcp.ManagementTargets{ local: app.snapshot, worker: app.server_worker, servers: app.remote_servers, profiles: app.remote_profiles, server: app.server_snapshot, runtime: app.remote_snapshot }, app.development_remote_hub) {
			ui2.refresh()
		}
	}
	select {
		result := <-app.development_results {
			app.development_pending = false
			if result.error != '' {
				app.development_message = result.error
				return
			}
			app.development_service = result.service
			app.development_project = result.project
			app.development_application = result.application
			app.development_message = if result.service.selection().source_workspace {
				'源码工作区已授权；可用 MCP 初始化空目录或绑定已有项目，无需安装。'
			} else if result.application == '' {
				'本机工作区 MCP 已开启。安装后关闭此会话，再绑定应用。'
			} else {
				'应用开发上下文已就绪；切换应用会使旧预览失效，连接配置保持不变。'
			}
		}
		else {
		}
	}
}

fn (mut app Workshop) refresh_development_apps() {
	app.development_apps = []host.DevelopmentApplication{}
	app.development_message = ''
	app.development_catalog_project = host.Project{}
	if isnil(app.development_service) { app.development_application = '' }
	if app.environment_id != '' {
		app.development_message = 'MCP 仅支持本机应用开发，暂不支持远端运行环境。'
		return
	}
	if app.selected < 0 || app.selected >= app.projects.len { return }
	project := app.projects[app.selected]
	// Keep the displayed application inventory paired with the project it came from.
	app.development_catalog_project = project
	if !os.is_file(project.config_path) {
		app.development_message = '当前运行环境的配置文件不存在，请重新导入或选择其他运行环境。'
		return
	}
	app.development_apps = host.development_applications(project) or {
		app.development_message = err.msg()
		return
	}
	if isnil(app.development_service) {
		app.development_project = project
		app.development_application = if app.development_apps.any(it.id == app.workspace_application) {
			app.workspace_application
		} else if app.development_apps.len > 0 {
			app.development_apps[0].id
		} else {
			''
		}
	}
}

fn (mut app Workshop) sync_development_apps() {
	if app.environment_id != '' {
		if app.development_catalog_project.config_path != '' { app.refresh_development_apps() }
		return
	}
	if app.selected < 0 || app.selected >= app.projects.len { return }
	if app.development_catalog_project != app.projects[app.selected] {
		app.refresh_development_apps()
	}
}

fn (mut app Workshop) connect_development(application string) {
	if app.development_pending || app.environment_id != '' || app.selected < 0 || app.selected >= app.projects.len {
		return
	}
	if app.development_catalog_project != app.projects[app.selected] {
		app.refresh_development_apps()
		app.development_message = '运行环境已变化，请重新选择应用。'
		return
	}
	if !isnil(app.development_service) && app.development_service.selection().application.id == '' {
		app.development_message = '请先关闭工作区 MCP，再绑定应用。'
		return
	}
	selected := app.development_apps.filter(it.id == application)
	if selected.len != 1 { return }
	app.development_pending = true
	app.development_message = '等待当前操作完成，正在切换应用…'
	spawn development_connect(app.worker, app.development_service, app.development_catalog_project, application, selected[0].root, app.binary, app.development_results)
}

fn (mut app Workshop) handle_development_event(event string) bool {
	match event {
		'mcp_settings', 'mcp_refresh' {
			app.show_development = true
			app.refresh_development_apps()
		}
		'mcp_application' {
			value := ui2.text(event)
			for item in app.development_apps {
				if development_app_title(item) == value {
					if !isnil(app.development_service) {
						app.connect_development(item.id)
					} else {
						app.development_application = item.id
					}
					break
				}
			}
		}
		'mcp_source_open' {
			if !app.development_pending && isnil(app.development_service) && app.environment_id == '' {
				dirs := ui2.open_folder_dialog(
					title:     ui_text('选择源码工作区（无需安装）')
					directory: if app.development_project.workdir != '' {
						app.development_project.workdir + os.path_separator
					} else {
						os.home_dir()
					}
				)
				if dirs.len > 0 && ui_confirm('授权源码工作区 MCP', '允许受信任的客户端在此目录内绑定项目、编辑源码和运行 vhttpd？不会安装或复制现有项目。\n' + os.real_path(dirs[0])) {
					app.development_pending = true
					spawn development_source_connect(app.worker, dirs[0], app.binary, app.development_results)
				}
			}
		}
		'mcp_workspace_start' {
			if !app.development_pending && isnil(app.development_service) && app.environment_id == ''
				&& app.selected >= 0 && app.selected < app.projects.len {
				project := app.projects[app.selected]
				if ui_confirm('开启本机工作区 MCP', '允许受信任的 MCP 客户端读写此运行环境目录并安装应用？\n' + project.workdir) {
					app.development_pending = true
					spawn development_connect(app.worker, app.development_service, project, '', '', app.binary, app.development_results)
				}
			}
		}
		'mcp_start', 'mcp_bind' { app.connect_development(app.development_application) }
		'mcp_remote_hub_target' {
			projects := app.server_snapshot.projects.filter(it.id == app.remote_id)
			if !app.server_snapshot.connected || app.server_snapshot.server_id != app.environment_id
				|| projects.len != 1 {
				return true
			}
			app.development_remote_hub = host.McpHubTarget{ worker: app.server_worker, server: app.server_snapshot.server, project_id: app.remote_id, runtime_id: projects[0].runtime_id }
			app.development_message = '已选择专用 Hub 目标。返回本机 MCP 页填写 HTTPS 地址，再调用 relay_status 和 relay_create_prepare。'
		}
		'mcp_relay_refresh' {
			app.development_remote_hub = host.McpHubTarget{}
			app.development_relay_choices = host.load_shared_relays() or {
				app.development_message = err.msg()
				return true
			}
			app.development_relay_choices = app.development_relay_choices.filter(it.is_native() && it.url.starts_with('wss://'))
			if !app.development_relay_choices.any(it.id == app.development_relay_id) {
				app.development_relay_id = if app.development_relay_choices.len == 1 {
					app.development_relay_choices[0].id
				} else {
					''
				}
			}
		}
		'mcp_relay_target' {
			value := ui2.text(event)
			for relay in app.development_relay_choices {
				if development_relay_title(relay) == value {
					app.development_remote_hub = host.McpHubTarget{}
					app.development_relay_id = relay.id
					break
				}
			}
		}
		'mcp_relay_url' { app.development_relay_url = ui2.text(event) }
		'mcp_relay_read', 'mcp_relay_edit' {
			if app.development_pending || isnil(app.development_service) { return true }
			targets := app.development_relay_choices.filter(it.id == app.development_relay_id)
			if targets.len != 1 {
				app.development_message = '请先从本机 Relay 连接库选择目标。'
				return true
			}
			writable := event == 'mcp_relay_edit'
			if writable && !ui_confirm('授权 Relay 编辑', '授权远端客户端修改当前应用源码并启停整个本地运行环境。授权在一小时后到期。') {
				return true
			}
			app.development_service.publish_relay(app.worker, desktop_version, targets[0], app.development_relay_url.trim_space(), writable) or {
				app.development_message = err.msg()
				return true
			}
			app.development_message = 'Relay Agent 已启动，可用下方的 HTTPS 地址和 Bearer 配置客户端。'
		}
		'mcp_relay_revoke' {
			if !app.development_pending && !isnil(app.development_service) {
				app.development_service.revoke_relay()
				app.development_message = if app.development_service.relay_cleanup_pending() {
					'本机授权已撤销。远端 Hub 待回收，请重新连接原服务器后重试。'
				} else {
					'Relay 授权已撤销。'
				}
			}
		}
		'mcp_stop' {
			if app.development_pending { return true }
			if !isnil(app.development_service) {
				app.development_service.close()
				app.development_service = unsafe { nil }
			}
			app.development_message = 'MCP 已关闭。'
			app.refresh_development_apps()
		}
		'mcp_new_application' {
			app.show_development = false
			app.handle_component_event('application_new_open')
		}
		'mcp_back' { app.show_development = false }
		else { return false }
	}
	return true
}

fn development_mcp_view(app &Workshop, width f64) []ui2.Element {
	running := !isnil(app.development_service)
	source_mode := running && app.development_service.selection().source_workspace
	busy := app.development_pending
	selected := app.development_apps.filter(it.id == app.development_application)
	title := if selected.len == 1 {
		development_app_title(selected[0])
	} else {
		ui_text('请选择应用')
	}
	choices := if app.development_apps.len == 0 {
		[title]
	} else {
		app.development_apps.map(development_app_title(it))
	}
	mut rows := [
		label('mcp_heading', '模型开发 · MCP', 0, 34, width - 130, 24, workbench_colors.ink),
		button('mcp_back', '返回工作台', width - 130, 34, 130, false, true),
		label('mcp_description', 'MCP 仅支持本机应用开发，暂不支持远端运行环境。', 0, 82, width, 13, workbench_colors.ink),
		label('mcp_scope', if app.environment_id != '' {
			'请在左侧切换到本机，再选择应用开启 MCP。'
		} else {
			'启停会影响当前运行环境中的全部应用。'
		}, 0, 114, width, 13, workbench_colors.muted),
		label('mcp_environment', '运行环境：' + app.workspace_name(), 0, 154, width, 13, workbench_colors.ink),
	]
	if app.environment_id != '' {
		rows << label('mcp_remote_unsupported', '远端运行环境暂不支持 MCP 开发', 0, 210, width, 18, workbench_colors.ink)
		rows << label('mcp_remote_apps', '远端应用仍可在应用页新建和安装。', 0, 250, width, 13, workbench_colors.muted)
		rows << button('mcp_new_application', '新建远端应用…', 0, 294, 180, false, !busy && app.remote_id != '')
		if running {
			binding := app.development_service.selection()
			rows << label('mcp_local_running', '本机 MCP 仍在运行，与当前远端环境无关。', 0, 358, width, 13, workbench_colors.ink)
			rows << label('mcp_binding', 'MCP 当前目标：' + binding.project.name + ' / ' + binding.application.label, 0, 394, width, 12, workbench_colors.ink)
			rows << button('mcp_stop', '关闭本机 MCP', 0, 434, 180, false, !busy)
			rows << button('mcp_remote_hub_target', '选择此环境作为 MCP Hub 目标', 0, 485, 280, false, !busy && app.server_snapshot.connected && app.server_snapshot.server_id == app.environment_id && app.server_snapshot.projects.any(it.id == app.remote_id))
			rows << label('mcp_remote_hub_status', app.development_message, 0, 535, width, 12, workbench_colors.muted)
		}
		return rows
	}
	rows << form_select('mcp_application', title, choices, ui2.rect(0, 194, width - 150, 36), !source_mode && !busy && app.development_apps.len > 0 && app.environment_id == '')
	rows << button('mcp_refresh', '刷新应用', width - 135, 194, 135, false, !busy)
	rows << button('mcp_new_application', '新建应用…', 0, 248, 150, false, !source_mode && !busy && (app.projects.len > 0 || app.remote_id != ''))
	rows << button(if running { 'mcp_stop' } else { 'mcp_start' }, if running {
		'关闭 MCP'
	} else {
		'绑定目录并开启 MCP'
	}, 166, 248, 150, true, !busy && (running || (selected.len == 1 && app.environment_id == '')))
	mut details_y := 300.0
	extra_action_x := if width >= 660 { 332.0 } else { 0.0 }
	extra_action_y := if width >= 660 { 248.0 } else { 294.0 }
	extra_action_width := if width >= 660 { width - 332 } else { width }
	if !running {
		rows << button('mcp_workspace_start', '开启本机工作区 MCP', extra_action_x, extra_action_y, extra_action_width, false, !busy && app.selected >= 0 && app.selected < app.projects.len)
		if width < 660 { details_y = 346 }
		rows << button('mcp_source_open', '打开源码目录（无需安装）…', 0, details_y, width, false, !busy)
		details_y += 48
	}
	if running {
		binding := app.development_service.selection()
		if !source_mode && binding.application.id != '' && app.selected >= 0 && app.selected < app.projects.len && binding.project != app.projects[app.selected] {
			rows << button('mcp_bind', '切换到当前环境', extra_action_x, extra_action_y, extra_action_width, false, !busy && selected.len == 1 && app.environment_id == '')
			if width < 660 { details_y = 346 }
		}
	}
	if source_mode {
		binding := app.development_service.selection()
		rows << label('mcp_source_root', '源码工作区：' + binding.project.workdir + '（原位开发，未安装）', 0, details_y, width, 12, workbench_colors.ink)
		details_y += 34
	}
	if !source_mode && selected.len == 1 {
		rows << label('mcp_source_root', '项目目录：' + selected[0].root, 0, details_y, width, 12, workbench_colors.ink)
		details_y += 34
	}
	if app.development_message != '' {
		rows << label('mcp_status', app.development_message, 0, details_y, width, 12, workbench_colors.muted)
		details_y += 34
	}
	if running {
		binding := app.development_service.selection()
		rows << label('mcp_binding', if binding.application.id == '' {
			'MCP 工作区：' + app.development_project.workdir
		} else {
			'MCP 当前目标：' + binding.project.name + ' / ' + binding.application.label
		}, 0, details_y, width, 12, workbench_colors.ink)
		details_y += 34
		rows << label('mcp_credentials_note', '连接配置含访问凭据，仅粘贴到受信任的 MCP 客户端。', 0, details_y, width, 12, workbench_colors.ink)
		details_y += 36
		config := ui2.text_area('mcp_connection_config', app.development_service.connection_config(), ui2.rect(0, details_y, width, 230), ui2.BoxStyle{ bg: workbench_colors.sidebar }, ui2.TextStyle{ font_family: workbench_mono_font, size: 12 })
		rows << ui2.Element{ ...config, readonly: true }
		details_y += 254
	}
	if running && app.development_service.selection().application.id != '' {
		targets := app.development_relay_choices.filter(it.id == app.development_relay_id)
		target_title := if app.development_remote_hub.project_id != '' {
			ui_text('远端专用 MCP Hub')
		} else if targets.len == 1 {
			development_relay_title(targets[0])
		} else {
			ui_text('请选择 Relay')
		}
		choices_relay := app.development_relay_choices.map(development_relay_title(it))
		rows << form_select('mcp_relay_target', target_title, choices_relay, ui2.rect(0, details_y, width - 150, 36), !busy && choices_relay.len > 0)
		rows << button('mcp_relay_refresh', '加载本机 Relay', width - 135, details_y, 135, false, !busy)
		rows << input('mcp_relay_url', app.development_relay_url, '公网 HTTPS MCP 地址', 0, details_y + 46, width, !busy)
		can_publish := !busy && app.development_remote_hub.project_id == '' && targets.len == 1 && app.development_relay_url != ''
		rows << button('mcp_relay_read', '发布 Relay 只读', 0, details_y + 94, 166, false, can_publish)
		rows << button('mcp_relay_edit', '发布 Relay 编辑', 174, details_y + 94, 166, false, can_publish)
		relay_config := app.development_service.relay_config()
		if relay_config != '' || app.development_service.relay_cleanup_pending() {
			rows << button('mcp_relay_revoke', '撤销 Relay 授权', 348, details_y + 94, 146, false, !busy)
		}
		if relay_config != '' {
			config := ui2.text_area('mcp_relay_config', relay_config, ui2.rect(0, details_y + 144, width, 230), ui2.BoxStyle{ bg: workbench_colors.sidebar }, ui2.TextStyle{ font_family: workbench_mono_font, size: 12 })
			rows << ui2.Element{ ...config, readonly: true }
		}
		return rows
	}
	rows << label('mcp_recovery', '选择应用 → 预览修改 → 校验 → 应用 → 运行验证。', 0, details_y + 12, width, 12, workbench_colors.muted)
	return rows
}

fn development_app_title(app host.DevelopmentApplication) string {
	return if app.label == app.id { app.label } else { app.label + ' · ' + app.id }
}

fn development_relay_title(relay host.SharedRelay) string {
	return relay.name + ' · ' + relay.id
}
