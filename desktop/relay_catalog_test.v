module main

import host
import ui2

fn test_catalog_is_scoped_and_remote_navigation_wins_over_other_pages() ! {
	local := host.SharedRelay{ id: 'ab'.repeat(12), relay_id: 'hub', name: 'Local', url: 'ws://localhost/relay' }
	remote := host.SharedRelay{ id: 'cd'.repeat(12), protocol: 'websocket', name: 'Paseo', url: 'wss://paseo.example/ws?v=2' }
	mut app := Workshop{
		environment_id:         'server'
		shared_relays:          [local]
		show_remote:            true
		show_runtime:           true
		show_component_install: true
		server_snapshot:        host.ServerSnapshot{ connected: true, server_id: 'server', relay_catalog: host.RelayCatalog{ loaded: true, entries: [remote] } }
		shared_token:           'old-private-token'
	}
	app.open_relay_catalog()
	assert app.show_shared_relays && !app.show_remote && !app.show_runtime && !app.show_component_install
	assert app.shared_token == ''
	assert app.catalog_items() == [remote]
	app.shared_catalog_pending = false
	app.server_busy = false
	assert app.handle_shared_relay_event('shared_new')
	assert app.shared_id.len == 24
	for width in [488.0, 708.0] {
		ui2.validate_element_tree(ui2.screen(workbench_paper, shared_relays_view(&app, width)))!
	}
	app.shared_protocol = 'websocket'
	for width in [488.0, 708.0] {
		ui2.validate_element_tree(ui2.screen(workbench_paper, shared_relays_view(&app, width)))!
	}
	app.environment_id = ''
	app.open_relay_catalog()
	assert app.catalog_items() == [local] && app.shared_id == local.id && app.shared_token == ''
	app.environment_id = 'another-server'
	assert app.catalog_items().len == 0 && !app.catalog_ready()
}

fn test_relay_service_inventory_includes_hub_and_websocket_application() {
	data := host.RuntimeWorkspace{
		known:                 true
		relays:                [host.ApplicationItem{ id: 'bodytest_database', kind: 'hub' }]
		applications:          [host.RuntimeApplication{ id: 'paseo', label: 'Paseo', status: 'configured', listeners: [host.ApplicationListener{ id: 'paseo', protocol: 'websocket', port: 19901 }] }]
		websocket_known:       true
		websocket_connections: 2
	}
	app := Workshop{ snapshot: host.Snapshot{ workspace: data } }
	text := app.relay_service_lines().join('\n')
	assert text.contains('bodytest_database') && text.contains('Paseo') && text.contains('19901')
	assert text.contains('应用 WebSocket 合计：活动连接 2')
}

fn test_remote_catalog_save_never_sends_a_local_project_command() {
	mut app := Workshop{
		environment_id:  'server'
		shared_id:       'ab'.repeat(12)
		shared_protocol: 'websocket'
		shared_name:     'Paseo'
		shared_url:      'wss://example/ws?v=2'
		server_snapshot: host.ServerSnapshot{ connected: true, server_id: 'server', server: host.RemoteServer{ id: 'server' }, relay_catalog: host.RelayCatalog{ loaded: true, revision: 'expected' } }
	}
	assert app.handle_shared_relay_event('shared_save')
	command := <-app.server_worker.commands
	assert command.action == .relay_save && command.server.id == 'server'
	assert command.relay_revision == 'expected' && command.shared_relay.protocol == 'websocket'
	select {
		_ := <-app.worker.commands {
			assert false, 'Remote operation targeted local project'
		}
		else {
		}
	}
}

fn test_empty_catalog_displays_remote_connection_errors() ! {
	app := Workshop{ environment_id: 'server', shared_message: '请先连接所选远端服务器，再刷新连接库。' }
	for width in [488.0, 708.0] {
		rows := shared_relays_view(&app, width)
		ui2.validate_element_tree(ui2.screen(workbench_paper, rows))!
		assert rows.len > 0
	}
}

fn test_library_separates_saved_settings_services_and_binding() ! {
	entry := host.SharedRelay{id:'ef'.repeat(12),name:'Socket',protocol:'websocket',url:'wss://example.org/ws?v=2'}
	mut app := Workshop{shared_relays:[entry],snapshot:host.Snapshot{workspace:host.RuntimeWorkspace{known:true,relays:[host.ApplicationItem{id:'hub',kind:'hub'}]}}}
	app.open_relay_catalog()
	assert app.shared_id == entry.id && !app.shared_services_tab
	for width in [488.0,708.0] {
		root := ui2.screen(workbench_paper,shared_relays_view(&app,width))
		ui2.validate_element_tree(root)!
		assert catalog_has_id(root,'shared_name') && catalog_has_id(root,'shared_token')
		assert !catalog_has_id(root,'shared_remote_id') && !catalog_has_id(root,'shared_db_local')
		assert !catalog_has_id(root,'shared_service_native_hub')
	}
	assert app.handle_shared_relay_event('shared_tab_services')
	root := ui2.screen(workbench_paper,shared_relays_view(&app,488))
	ui2.validate_element_tree(root)!
	assert catalog_has_id(root,'shared_service_native_hub') && !catalog_has_id(root,'shared_name')
	assert app.shared_id == entry.id
	assert app.handle_shared_relay_event('shared_tab_connections')
	assert app.handle_shared_relay_event('shared_detail_history')
	assert catalog_has_id(ui2.screen(workbench_paper,shared_relays_view(&app,488)),'shared_probe_history')
	assert app.sequence == 0
}

fn catalog_has_id(element ui2.Element, id string) bool {
	if element.id == id {return true}
	return element.children.any(catalog_has_id(it,id))
}
