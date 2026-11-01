module main

import host
import ui2

fn runtime_element_text(element ui2.Element) string {
	mut text := element.text
	for child in element.children { text += '\n' + runtime_element_text(child) }
	return text
}

fn runtime_element_action(element ui2.Element, id string) bool {
	if element.id == id { return element.enabled }
	return element.children.any(runtime_element_action(it, id))
}

fn runtime_element(element ui2.Element, id string) ?ui2.Element {
	if element.id == id { return element }
	for child in element.children { if found := runtime_element(child, id) { return found } }
	return none
}

fn runtime_flow_fixture() Workshop {
	server := host.RemoteServer{ id: 'bullsoft', name: 'bullsoft', ssh_host: 'example.test', ssh_user: 'test', ssh_port: 22 }
	return Workshop{
		runtime_server_id: 'bullsoft'
		environment_id:    'bullsoft'
		remote_id:         'bullsoft'
		remote_name:       'bullsoft'
		remote_host:       'example.test'
		remote_user:       'test'
		remote_port:       '22'
		remote_snapshot:   host.RemoteSnapshot{ profile_id: 'bodytest' }
		remote_servers:    [server]
		server_snapshot:   host.ServerSnapshot{
			server_id: 'bullsoft'
			server:    server
			connected: true
			platform:  'linux-amd64'
			root:      '/runtime'
			message:   '远端连接库已刷新。'
			runtimes:  [
				host.RemoteRuntime{ id: 'old', version: '0.1.0', release_tag: 'build-old' },
				host.RemoteRuntime{ id: 'new', version: '0.1.0', release_tag: 'build-new' },
			]
			projects:  [
				host.RemoteProfile{ id: 'bodytest', name: 'bodytest', runtime_id: 'old', config_path: '/runtime/instances/bodytest/vhttpd.toml' },
				host.RemoteProfile{ id: 'other', name: 'other', runtime_id: 'new', config_path: '/runtime/instances/other/vhttpd.toml' },
			]
			upgrades:  [
				host.RemoteRuntimeUpgrade{ id: 'old-operation', config_path: '/runtime/instances/bodytest/vhttpd.toml', phase: 'completed', previous_id: 'new', target_id: 'old' },
				host.RemoteRuntimeUpgrade{ id: 'other-operation', config_path: '/runtime/instances/other/vhttpd.toml', phase: 'completed' },
			]
		}
	}
}

fn test_runtime_page_defaults_to_current_binding_and_hides_history() ! {
	app := runtime_flow_fixture()
	assert app.selected_upgrade_project() == 'bodytest'
	assert app.selected_server_runtime() == 'old'
	for width in [488.0, 708.0] {
		root := ui2.screen(workbench_paper, runtime_remote_view(app, width))
		ui2.validate_element_tree(root)!
		text := runtime_element_text(root)
		assert text.contains('此环境正在使用')
		assert !text.contains('升级成功')
		assert !text.contains('远端连接库已刷新')
		assert !runtime_element_action(root, 'server_upgrade')
		assert !runtime_element_action(root, 'server_create')
	}
}

fn test_package_selection_only_changes_the_preview_until_confirmed() {
	mut app := runtime_flow_fixture()
	app.handle_server_event('server_runtime_choice_new')
	assert app.selected_server_runtime() == 'new'
	assert app.server_sequence == 0
	root := ui2.screen(workbench_paper, runtime_remote_view(app, 488))
	assert runtime_element_action(root, 'server_upgrade')
	text := runtime_element_text(root)
	assert text.contains('当前：vhttpd 0.1.0 · build-old')
	assert text.contains('目标：vhttpd 0.1.0 · build-new')
	assert text.contains('全部应用将短暂停机')
	app.runtime_history_open = true
	history := runtime_element_text(ui2.screen(workbench_paper, runtime_remote_view(app, 488)))
	assert history.contains('历史记录 · bodytest')
	assert !history.contains('历史记录 · other')
}

fn test_only_a_new_upgrade_from_this_flow_is_shown_as_a_result() {
	mut app := runtime_flow_fixture()
	app.runtime_operation_sequence = 8
	app.runtime_operation_server = 'bullsoft'
	app.runtime_upgrade_before = ['old-operation', 'other-operation']
	app.server_snapshot = host.ServerSnapshot{ ...app.server_snapshot, runtime_result: host.OperationResult{ sequence: 8, action: 'upgrade', target: 'bodytest' }, upgrades: app.server_snapshot.upgrades.clone() }
	old := runtime_element_text(ui2.screen(workbench_paper, runtime_remote_view(app, 488)))
	assert !old.contains('本次切换已完成')
	mut upgrades := app.server_snapshot.upgrades.clone()
	upgrades << host.RemoteRuntimeUpgrade{ id: 'new-operation', config_path: '/runtime/instances/bodytest/vhttpd.toml', target_id: 'new', phase: 'completed' }
	app.server_snapshot = host.ServerSnapshot{ ...app.server_snapshot, upgrades: upgrades }
	current := runtime_element_text(ui2.screen(workbench_paper, runtime_remote_view(app, 488)))
	assert current.contains('本次切换已完成 · bodytest')
}

fn test_current_package_is_visible_first_and_creation_feedback_does_not_overlap() ! {
	mut app := runtime_flow_fixture()
	app.server_snapshot = host.ServerSnapshot{ ...app.server_snapshot, runtimes: app.server_snapshot.runtimes.reverse() }
	root := ui2.screen(workbench_paper, runtime_remote_view(app, 488))
	library := runtime_element(root, 'runtime_package_library') or { panic('missing package library') }
	assert library.children[0].id == 'runtime_package_row_old'
	app.runtime_create_open = true
	app.runtime_form_error = '端口请填写数字'
	create := ui2.screen(workbench_paper, runtime_remote_view(app, 488))
	ui2.validate_element_tree(create)!
	button := runtime_element(create, 'server_create_container') or { panic('missing create action') }
	feedback := runtime_element(create, 'runtime_operation_error') or { panic('missing error feedback') }
	assert feedback.frame.y >= button.frame.y + button.frame.height
}
