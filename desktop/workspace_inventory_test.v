module main

import host
import ui2

fn test_unknown_inventory_never_displays_zero_installed_apps() ! {
	app := Workshop{ projects: [host.Project{ name: 'fixture' }] }
	rows := workspace_applications_view(&app, host.RuntimeWorkspace{}, 800, 850, false)
	count := inventory_test_element(rows, 'workspace_apps_count')!
	assert count.text == '已安装应用 · 未确认'
}

fn test_offline_inventory_remains_selectable_and_labels_its_source() ! {
	app := Workshop{ projects: [host.Project{ name: 'fixture' }] }
	data := host.RuntimeWorkspace{ inventory_known: true, from_configuration: true, applications: [
		host.RuntimeApplication{ id: 'alpha', status: 'configured' },
		host.RuntimeApplication{ id: 'beta', status: 'configured' },
	] }
	rows := workspace_applications_view(&app, data, 800, 850, false)
	assert inventory_test_element(rows, 'workspace_apps_count')!.text == '已安装应用 · 2'
	assert inventory_test_element(rows, 'workspace_application_alpha')!.enabled
	assert inventory_test_element(rows, 'workspace_application_beta')!.enabled
	assert inventory_test_element(rows, 'workspace_application_details')!.text.contains('本地配置；运行状态未确认')
	ui2.validate_element_tree(ui2.screen(workbench_colors.paper, rows))!
}

fn inventory_test_element(elements []ui2.Element, id string) !ui2.Element {
	for element in elements {
		if element.id == id { return element }
		found := inventory_test_element(element.children, id) or { continue }
		return found
	}
	return error('missing inventory element: ' + id)
}
