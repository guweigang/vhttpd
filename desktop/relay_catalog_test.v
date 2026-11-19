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
		ui2.validate_element_tree(ui2.screen(workbench_colors.paper, shared_relays_view(&app, width)))!
	}
	app.shared_protocol = 'websocket'
	for width in [488.0, 708.0] {
		ui2.validate_element_tree(ui2.screen(workbench_colors.paper, shared_relays_view(&app, width)))!
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
		ui2.validate_element_tree(ui2.screen(workbench_colors.paper, rows))!
		assert rows.len > 0
	}
}

fn test_saved_connections_do_not_duplicate_runtime_service_inventory() ! {
	entry := host.SharedRelay{id:'ef'.repeat(12),name:'Socket',protocol:'websocket',url:'wss://example.org/ws?v=2'}
	mut app := Workshop{shared_relays:[entry],snapshot:host.Snapshot{workspace:host.RuntimeWorkspace{known:true,relays:[host.ApplicationItem{id:'hub',kind:'hub'}]}}}
	app.open_relay_catalog()
	assert app.shared_id == entry.id
	for width in [488.0,708.0] {
		root := ui2.screen(workbench_colors.paper,shared_relays_view(&app,width))
		ui2.validate_element_tree(root)!
		assert catalog_has_id(root,'shared_name') && catalog_has_id(root,'shared_token')
		assert !catalog_has_id(root,'shared_remote_id') && !catalog_has_id(root,'shared_db_local')
		assert !catalog_has_id(root,'shared_service_native_hub')
	}
	assert !catalog_has_id(ui2.screen(workbench_colors.paper,shared_relays_view(&app,488)), 'shared_tab_services')
	assert app.handle_shared_relay_event('shared_detail_history')
	assert catalog_has_id(ui2.screen(workbench_colors.paper,shared_relays_view(&app,488)),'shared_probe_history')
	assert app.sequence == 0
}

fn catalog_has_id(element ui2.Element, id string) bool {
	if element.id == id {return true}
	return element.children.any(catalog_has_id(it,id))
}

fn test_unsaved_remote_draft_is_sent_only_to_its_ssh_host() {
	entry := host.SharedRelay{id:'12'.repeat(12),name:'Draft',url:'ws://127.0.0.1:19881/relay',relay_id:'hub',token:'draft-private-token'}
	mut app := Workshop{environment_id:'server',server_snapshot:host.ServerSnapshot{connected:true,server_id:'server',server:host.RemoteServer{id:'server',name:'Linux QA',ssh_host:'qa.example'}}}
	app.start_shared_relay_test(entry)
	assert app.shared_testing && app.shared_test_scope == 'server'
	assert app.shared_test_form == entry && app.shared_test_host.contains('qa.example')
	command := <-app.server_worker.commands
	assert command.action == .relay_probe && command.server.id == 'server'
	assert command.shared_relay == entry
	command.relay_probe_reply <- host.RelayProbeResult{ok:true,stage:'Relay 认证',message:'fixture'}
	assert (<-app.shared_results).ok
	assert app.catalog_items().len == 0, 'Testing must not save the draft'
	select { _ := <-app.worker.commands { assert false, 'Remote probe dispatched a local project operation' } else {} }
}

fn test_remote_probe_requires_matching_connected_idle_host_without_local_fallback() {
	entry := host.SharedRelay{id:'34'.repeat(12),name:'Draft',url:'ws://127.0.0.1/relay',relay_id:'hub'}
	for snapshot in [host.ServerSnapshot{},host.ServerSnapshot{connected:true,server_id:'other'},host.ServerSnapshot{connected:true,server_id:'server',busy:true}] {
		mut app := Workshop{environment_id:'server',server_snapshot:snapshot,shared_id:entry.id,shared_message:'连接已修改，保存或测试后再使用。'}
		app.start_shared_relay_test(entry)
		assert !app.shared_testing
		assert app.shared_message.contains('远端主机')
		root := ui2.screen(workbench_colors.paper,shared_relays_view(&app,488))
		assert catalog_text(root).contains('请先连接所选远端主机')
		assert !menu_button_enabled(root,'shared_test')
		select { _ := <-app.server_worker.commands { assert false, 'Disconnected/busy/wrong host must not receive a probe' } else {} }
		select { _ := <-app.shared_results { assert false, 'Must not fall back to a local probe' } else {} }
	}
}

fn test_probe_results_are_bound_to_parameters_and_library_returns_to_relay() {
	entry := host.SharedRelay{id:'56'.repeat(12),name:'Draft',url:'ws://127.0.0.1/relay',relay_id:'hub',token:'old'}
	assert shared_status_key('host',entry) != shared_status_key('other',entry)
	assert shared_status_key('host',entry) != shared_status_key('host',host.SharedRelay{...entry,token:'new'})
	assert shared_status_key('host',entry) != shared_status_key('host',host.SharedRelay{...entry,url:'ws://127.0.0.1/other'})
	mut app := Workshop{environment_id:'host',show_shared_relays:true}
	assert app.handle_shared_relay_event('shared_close')
	assert !app.show_shared_relays && app.show_remote && app.workspace_page == .relay
	menus := app.workbench_menus(ui2.screen(workbench_colors.paper,[]))
	for menu in menus { assert menu_find(menu.items,'menu:shared_relays') == none }
}

fn catalog_text(element ui2.Element) string {
	mut text := element.text
	for child in element.children { text += catalog_text(child) }
	return text
}
