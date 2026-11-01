module main

import host
import ui2

fn test_relay_service_rows_keep_unknown_and_idle_distinct() {
	mut data := host.RuntimeWorkspace{known:true,relays:[host.ApplicationItem{id:'db',kind:'hub'}],applications:[host.RuntimeApplication{id:'socket',label:'Socket app',listeners:[host.ApplicationListener{id:'socket',protocol:'websocket',host:'127.0.0.1',port:19901}]}]}
	unknown := relay_service_rows(data)
	assert unknown.len == 2 && unknown[0].status == '状态未确认'
	assert unknown[1].metrics == '连接数尚未确认'
	data = host.RuntimeWorkspace{...data,relay:host.RelayLiveStatus{known:true},websocket_known:true,websocket_listeners:[host.WorkspaceWebSocketListener{listener_ids:['socket']}]}
	idle := relay_service_rows(data)
	assert idle[0].status == '接收端就绪'
	assert idle[1].status == '等待连接' && idle[1].metrics.starts_with('0 个连接')
	data = host.RuntimeWorkspace{...data,websocket_listeners:[host.WorkspaceWebSocketListener{listener_ids:['socket'],active_connections:5,active_rooms:3}]}
	assert relay_service_rows(data)[1].metrics == '5 个连接   ·   3 个房间'
}

fn test_relay_overview_has_structured_services_and_preserves_application_actions() ! {
	data := host.RuntimeWorkspace{known:true,relays:[host.ApplicationItem{id:'bodytest_database',kind:'hub'}],applications:[host.RuntimeApplication{id:'paseo',label:'Paseo',listeners:[host.ApplicationListener{id:'paseo',protocol:'websocket',host:'127.0.0.1',port:19901}]}]}
	mut app := Workshop{snapshot:host.Snapshot{workspace:data}}
	for width in [488.0,708.0] {
		root := ui2.screen(workbench_paper,relay_overview_view(&app,width,false))
		ui2.validate_element_tree(root)!
		assert !relay_view_has_id(root,'workspace_relay_connections')
		assert relay_view_has_id(root,'workspace_application_paseo')
	}
	assert app.handle_workspace_event('workspace_application_paseo')
	assert app.workspace_page == .applications && app.workspace_application == 'paseo'
	assert app.sequence == 0
}

fn relay_view_has_id(element ui2.Element, id string) bool {
	if element.id == id { return true }
	return element.children.any(relay_view_has_id(it,id))
}
