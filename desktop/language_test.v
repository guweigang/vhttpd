module main

import application_logs
import host
import l10n
import os
import ui2

fn test_language_switch_changes_presentation_without_mutating_model_data() ! {
	previous := workbench_language
	defer { workbench_language = previous }
	root := ui2.screen(workbench_paper, [
		label('project_label', '运行环境', 0, 0, 180, 14, workbench_muted),
		label('workspace_title', '运行环境', 0, 40, 180, 14, workbench_ink),
		input('new_name', '运行环境', '项目名称', 0, 80, 300, true),
		workspace_text('workspace_logs', '运行环境\n配置已生效', 130, 300, 100),
		ui2.dropdown('server_upgrade_environment', '运行环境', ['运行环境', '日志'], ui2.rect(0, 240, 300, 36), ui2.BoxStyle{}, ui2.TextStyle{}),
	])
	workbench_language = 'en'
	english := localize_element(root)
	assert english.children[0].text == 'Environments'
	assert english.children[1].text == '运行环境'
	assert english.children[2].text == '运行环境'
	assert english.children[2].accessibility_label == 'Project name'
	assert english.children[3].text == '运行环境\n配置已生效'
	assert english.children[4].text == '运行环境'
	assert english.children[4].menu == root.children[4].menu
	workbench_language = 'zh-CN'
	assert localize_element(root) == root
}

fn language_menu_item(menus []ui2.Menu, action string) ui2.MenuItem {
	for menu in menus {
		if item := menu_find(menu.items, 'menu:' + action) { return item }
	}
	panic('missing menu action: ' + action)
}

fn test_localized_menu_keeps_action_ids_targets_and_language_choices() {
	previous := workbench_language
	defer { workbench_language = previous }
	app := Workshop{ projects: [host.Project{ name: '运行环境', config_path: '/tmp/example.toml' }] }
	workbench_language = 'en'
	menus := app.workbench_menus(ui2.screen(workbench_paper, []))
	assert menus[0].title == 'File'
	assert menus[2].title == 'Environments'
	assert language_menu_item(menus, 'edit_copy').title == 'Copy'
	assert language_menu_item(menus, 'start').title == 'Start environment'
	assert language_menu_item(menus, 'project_0').title == '运行环境'
	assert language_menu_item(menus, 'language:auto').title == 'Follow system'
	assert language_menu_item(menus, 'language:zh-CN').title == '简体中文'
	assert language_menu_item(menus, 'language:en').title == 'English'
	assert localize_menu_item(ui2.MenuItem{ id: 'menu:remote_select_x', title: '运行环境' }).title == '运行环境'
	assert localize_menu_item(ui2.MenuItem{ id: 'menu:environment:x', title: '远端 · 文件' }).title == 'Remote · 文件'
	assert localize_menu_item(ui2.MenuItem{ id: 'menu:environment:profile:x', title: 'SSH · 文件' }).title == 'SSH · 文件'
}

fn test_language_change_persists_without_replacing_connection_or_form_state() ! {
	previous_language := workbench_language
	previous_preference := workbench_language_preference
	previous_file := workbench_language_file
	previous_system := workbench_system_language
	mut app := unsafe { workshop }
	saved_remote := app.remote_snapshot
	saved_name := app.new_name
	root := os.join_path(os.temp_dir(), 'vhttpd-ui-language-' + os.getpid().str())
	defer {
		workbench_language = previous_language
		workbench_language_preference = previous_preference
		workbench_language_file = previous_file
		workbench_system_language = previous_system
		app.remote_snapshot = saved_remote
		app.new_name = saved_name
		os.rmdir_all(root) or {}
	}
	app.remote_snapshot = host.RemoteSnapshot{ profile_id: 'bodytest', connected: true, instance: host.RemoteInstance{ version: '0.1.0', ready: true } }
	app.new_name = '中文 draft'
	before := app.remote_snapshot
	workbench_language_file = os.join_path(root, 'language.json')
	workbench_system_language = 'zh-CN'
	choose_language('en')
	assert workbench_language == 'en'
	assert l10n.load_preferences(workbench_language_file)!.language == 'en'
	assert app.remote_snapshot == before
	assert app.new_name == '中文 draft'
	choose_language('auto')
	assert workbench_language == 'zh-CN'
	assert l10n.load_preferences(workbench_language_file)!.language == 'auto'
	assert app.remote_snapshot == before
	assert app.new_name == '中文 draft'
}

fn test_empty_log_hints_translate_but_application_messages_stay_original() {
 previous := workbench_language
 defer {workbench_language = previous}
 workbench_language='en'
 unknown := host.RuntimeWorkspace{}
 assert application_log_lines(unknown,'app','application')[0].starts_with('App logs have not loaded')
 data := host.RuntimeWorkspace{application_logs:{'app':application_logs.Snapshot{records:[application_logs.Record{app_id:'app',source:'console',level:'info',message:'运行环境'}]}}}
 assert application_log_lines(data,'app','stdout')[0].ends_with('运行环境')
 assert application_log_lines(data,'app','runtime')==['No logs from this source for this app.']
}

fn test_configuration_preview_translates_wording_but_preserves_values_and_actions() {
 previous := workbench_language
 defer {workbench_language=previous}
 workbench_language='en'
 mut app:=Workshop{projects:[host.Project{name:'运行环境',config_path:'/tmp/config.toml'}],snapshot:host.Snapshot{phase:.stopped,rollback_preview:host.RollbackPreview{id:'preview',message:'回滚预览已生成，尚未修改项目文件。',fields:[host.ConfigFieldDiff{kind:'Pipeline',component:'main',field:'label',before:'运行环境',after:'配置已生效',change:'修改'}]}}}
 rows:=config_rollback_view(&app,708)
 details:=rows.filter(it.id=='rollback_details')[0].text
 assert details.contains('Current: 运行环境')
 assert details.contains('Restore to: 配置已生效')
 assert details.contains('Rollback preview generated')
 app.snapshot=host.Snapshot{phase:.stopped,message:'配置文件已恢复，整项目校验通过；启动后自动检查生效。'}
 root:=ui2.screen(workbench_paper,config_rollback_view(&app,708))
 assert menu_button_enabled(root,'start')
}

fn test_about_text_uses_selected_language_and_keeps_runtime_version() {
 previous:=workbench_language
 defer {workbench_language=previous}
 app:=Workshop{runtime_info:host.RuntimeInfo{ready:true,version:'0.1.0'}}
 workbench_language='en'
 english:=app.workbench_about_text()
 assert english.contains('Development workbench built with V / ui2')
 assert english.contains('Current environment:')
 assert english.contains('Local vhttpd 0.1.0')
 workbench_language='zh-CN'
 assert app.workbench_about_text().contains('基于 V / ui2 的开发工作台')
}

fn test_empty_application_picker_keeps_a_localized_disabled_placeholder() {
	previous:=workbench_language
	defer {workbench_language=previous}
	app:=Workshop{}
	for language,expected in {'en':'Select an app','zh-CN':'请选择应用'} {
		workbench_language=language
		rows:=development_mcp_view(app,708)
		picker:=rows.filter(it.id=='mcp_application')[0]
		assert picker.text==expected
		assert picker.menu==[expected]
		assert !picker.enabled
		assert app.development_application==''
	}
}
