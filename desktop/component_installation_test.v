module main

import app_bundle
import host
import ui2

fn component_action(element ui2.Element, id string) bool {
	if element.id == id { return element.enabled }
	return element.children.any(component_action(it, id))
}

fn component_text(element ui2.Element) string {
	mut text := element.text
	for child in element.children { text += '\n' + component_text(child) }
	return text
}

fn test_new_installation_does_not_reuse_server_messages_or_old_deployments() {
	for remote in [false, true] {
		app := Workshop{ environment_id: if remote { 'bullsoft' } else { '' }, snapshot: host.Snapshot{ message: '上次操作成功' }, server_snapshot: host.ServerSnapshot{ connected: true, message: '远端连接库已刷新。', deployments: [host.ApplicationDeploymentStatus{ id: 'old', phase: 'completed' }] } }
		root := ui2.screen(workbench_paper, component_installation_view(app, 488))
		text := component_text(root)
		assert !component_action(root, 'component_message')
		assert !text.contains('操作状态')
		assert !text.contains('配置已生效')
		assert !text.contains('远端连接库已刷新')
	}
}

fn test_installation_feedback_is_bound_to_its_operation() {
	mut app := Workshop{ environment_id: 'bullsoft', component_target: 'bodytest', component_sequence: 7, component_action: 'preview', component_file: '/fixture/component.toml', component_name: 'demo', component_prepared_file: '/fixture/component.toml', component_prepared_name: 'demo', server_snapshot: host.ServerSnapshot{ deployment_preview: host.ApplicationDeploymentPreview{ id: 'preview' }, connected: true, message: '远端连接库已刷新', component_result: host.OperationResult{ sequence: 7, target: 'bodytest', action: 'preview', preview_id: 'preview' } } }
	title, message, _ := app.component_feedback()
	assert title == '预览检查通过'
	assert message.contains('尚未安装')
	app.component_action = 'install'
	app.component_operation_id = 'current'
	app.server_snapshot = host.ServerSnapshot{
		...app.server_snapshot
		deployments: [
			host.ApplicationDeploymentStatus{ id: 'old', phase: 'failed' },
			host.ApplicationDeploymentStatus{ id: 'current', phase: 'completed' },
		]
	}
	installed, detail, tone := app.component_feedback()
	assert installed.contains('成功') && detail.contains('本次') && tone == 'good'
	app.reset_component_preview()
	_, empty, _ := app.component_feedback()
	assert empty == ''
}

fn test_installation_target_can_use_the_live_server_inventory() {
	app := Workshop{ environment_id: 'bullsoft', component_target: 'bodytest', server_snapshot: host.ServerSnapshot{ projects: [host.RemoteProfile{ id: 'bodytest', name: 'bodytest' }] } }
	text := component_text(ui2.screen(workbench_paper, component_installation_view(app, 488)))
	assert text.contains('/ bodytest')
}

fn test_component_installation_preview_and_layout_are_bound_to_source() ! {
	for remote in [false, true] {
		preview := host.ApplicationDeploymentPreview{
			id:    'fixture-preview'
			files: [
				app_bundle.FileView{ path: 'apps/demo/main.mjs', action: 'add' },
				app_bundle.FileView{ path: 'vhttpd.toml', action: 'replace' },
			]
		}
		mut app := Workshop{ environment_id: if remote { 'server' } else { '' }, component_file: '/fixture/component.toml', component_name: 'demo', component_prepared_file: '/fixture/component.toml', component_prepared_name: 'demo', component_target: 'target', component_sequence: 7, component_action: 'preview', snapshot: host.Snapshot{ component_preview: preview, component_result: host.OperationResult{ sequence: 7, target: 'target', action: 'preview', preview_id: preview.id } }, server_snapshot: host.ServerSnapshot{ connected: true, deployment_preview: preview, component_result: host.OperationResult{ sequence: 7, target: 'target', action: 'preview', preview_id: preview.id } } }
		for width in [488.0, 708.0] {
			root := ui2.screen(workbench_paper, component_installation_view(app, width))
			ui2.validate_element_tree(root)!
			assert component_action(root, 'component_commit')
		}
		app.component_preview_before = preview.id
		assert !component_action(ui2.screen(workbench_paper, component_installation_view(app, 488)), 'component_commit')
		app.component_preview_before = ''
		if remote {
			app.server_snapshot = host.ServerSnapshot{...app.server_snapshot,deployment_preview:host.ApplicationDeploymentPreview{id:'unrelated-preview'}}
			assert !component_action(ui2.screen(workbench_paper,component_installation_view(app,488)),'component_commit')
			app.server_snapshot = host.ServerSnapshot{...app.server_snapshot,deployment_preview:preview}
		}
		app.component_name = 'another-app'
		assert !component_action(ui2.screen(workbench_paper, component_installation_view(app, 488)), 'component_commit')
	}
}

fn test_stopped_environment_still_offers_independent_install() ! {
	mut app := Workshop{ projects: [host.Project{ name: 'empty', config_path: '/fixture/vhttpd.toml' }], workspace_page: .applications }
	root := ui2.screen(workbench_paper, runtime_workspace_view(mut app, 488, 740))
	ui2.validate_element_tree(root)!
	assert component_action(root, 'component_open')
}
