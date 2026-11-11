module main

import devmcp
import host
import os
import time
import ui2

fn test_mcp_selects_applications_without_directory_picker() ! {
	mut app := Workshop{}
	initial := ui2.screen(workbench_colors.paper, development_mcp_view(&app, 510))
	assert !menu_button_enabled(initial, 'mcp_start')
	assert !menu_button_enabled(initial, 'mcp_choose_root')
	ui2.validate_element_tree(initial)!
	app.projects = [host.Project{ name: 'environment', config_path: '/fixture/vhttpd.toml', workdir: '/fixture' }]
	app.development_apps = [host.DevelopmentApplication{ id: 'alpha', label: 'Alpha', root: '/fixture/apps/alpha' }]
	app.development_application = 'alpha'
	assert menu_button_enabled(ui2.screen(workbench_colors.paper, development_mcp_view(&app, 510)), 'mcp_start')
	app.development_service = &devmcp.Service{ url: 'http://127.0.0.1:12345/mcp', token: 'fixture-only' }
	active := development_mcp_view(&app, 510)
	assert mcp_control_enabled(ui2.screen(workbench_colors.paper, active), 'mcp_application')
	assert active.filter(it.id == 'mcp_connection_config')[0].readonly
	// Project details must clear the action row, including the narrow-window wrap.
	for width in [510.0, 708.0] {
		for enabled in [false, true] {
			if !enabled { app.development_service = unsafe { nil } }
			else { app.development_service = &devmcp.Service{ url: 'http://127.0.0.1:12345/mcp', token: 'fixture-only' } }
			app.development_message = '应用开发上下文已就绪。'
			page := development_mcp_view(&app, width)
			directory := page.filter(it.id == 'mcp_source_root')[0]
			for row in page {
				if row.id in ['mcp_new_application_container', 'mcp_start_container', 'mcp_stop_container', 'mcp_workspace_start_container', 'mcp_bind_container'] {
					assert row.frame.y + row.frame.height < directory.frame.y
					assert row.frame.width > 0
					assert row.frame.x + row.frame.width <= width
				}
			}
			status := page.filter(it.id == 'mcp_status')[0]
			assert status.frame.y >= directory.frame.y + directory.frame.height
			if enabled {
				binding := page.filter(it.id == 'mcp_binding')[0]
				assert binding.frame.y >= status.frame.y + status.frame.height
				config := page.filter(it.id == 'mcp_connection_config')[0]
				recovery := page.filter(it.id == 'mcp_recovery')[0]
				assert recovery.frame.y > config.frame.y + config.frame.height
			}
		}
	}
	ui2.validate_element_tree(ui2.screen(workbench_colors.paper, active))!
	app.development_pending = true
	assert !mcp_control_enabled(ui2.screen(workbench_colors.paper, development_mcp_view(&app, 510)), 'mcp_application')
}

fn test_mcp_environment_switch_refreshes_catalog_and_clears_missing_config_error() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'mcp-catalog-${os.getpid()}-${time.sys_mono_now()}')
	os.mkdir(root)!
	defer { os.rmdir_all(root) or {} }
	valid := host.create_project(host.CreateProjectOptions{ name: 'api-playground', parent_dir: root, template: 'vjsx-api' })!
	missing := host.Project{ name: 'relay-review', config_path: root + '/removed/vhttpd.toml', workdir: root + '/removed' }
	mut app := Workshop{ projects: [valid, missing], selected: 1 }
	app.refresh_development_apps()
	assert app.development_apps.len == 0
	assert app.development_application == ''
	assert app.development_message.contains('配置文件不存在')
	app.selected = 0
	app.sync_development_apps()
	assert app.development_catalog_project == valid
	assert app.development_apps.len > 0
	assert app.development_message == ''
	assert menu_button_enabled(ui2.screen(workbench_colors.paper, development_mcp_view(&app, 510)), 'mcp_start')
	application := app.development_application
	// A click queued for the old inventory must not bind a different project.
	app.selected = 1
	app.connect_development(application)
	assert !app.development_pending
	assert app.development_apps.len == 0
	assert app.development_message == '运行环境已变化，请重新选择应用。'
	app.selected = 0
	app.sync_development_apps()
	assert app.development_message == ''
	// Successful manual refresh also clears errors from a previous operation.
	app.development_message = 'failed to open file: relay-review/vhttpd.toml'
	app.refresh_development_apps()
	assert app.development_message == ''
	assert app.development_catalog_project == valid
}

fn mcp_control_enabled(element ui2.Element, id string) bool {
	if element.id == id { return element.enabled && !element.hidden }
	for child in element.children { if mcp_control_enabled(child, id) { return true } }
	return false
}
