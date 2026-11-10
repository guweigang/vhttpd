module main

import host
import ui2

fn audit_text(e ui2.Element) string {
 mut text := e.text
 for child in e.children { text += '\n' + audit_text(child) }
 return text
}

fn test_workspace_preserves_remote_configuration_and_failure_feedback() ! {
 mut app := Workshop{environment_id:'server',remote_name:'bodytest',remote_message:'配置预检失败：端口冲突',remote_snapshot:host.RemoteSnapshot{connected:true,instance:host.RemoteInstance{ready:true,manual_restart:true},config_status:host.ConfigStatus{pending:true}}}
 for width in [488.0,708.0] {
  root := ui2.screen(workbench_paper,runtime_workspace_view(mut app,width,740))
  ui2.validate_element_tree(root)!
  text := audit_text(root)
  assert text.contains('配置待重启生效') && text.contains('配置预检失败：端口冲突')
  assert text.contains('通过 SSH 隧道访问远端 Admin')
  assert menu_button_enabled(root,'remote_restart')
 }
 app.remote_snapshot = host.RemoteSnapshot{connected:true,instance:host.RemoteInstance{ready:false,manual_restart:true,operation:host.RemoteOperation{state:'failed',error:'executor_warmup_failed'}}}
 root := ui2.screen(workbench_paper,runtime_workspace_view(mut app,488,740))
 assert audit_text(root).contains('重启失败 · 需修复配置')
}

fn test_all_application_logs_clear_relay_source_and_stale_text() {
 mut app := Workshop{workspace_page:.logs,workspace_log_source:'relay',workspace_log_application:'paseo',workspace_logs_text:'old relay log'}
 assert app.handle_workspace_event('workspace_logs_all')
 assert app.workspace_log_source == '' && app.workspace_log_application == '' && app.workspace_logs_text == ''
}

fn test_relay_overview_exposes_takeover_before_local_start() ! {
 mut app := Workshop{projects:[host.Project{name:'bodytest'}],workspace_page:.relay}
 root := ui2.screen(workbench_paper,runtime_workspace_view(mut app,488,740))
 ui2.validate_element_tree(root)!
 assert menu_button_enabled(root,'takeover_open')
}

fn test_catalog_results_remain_scoped_to_connection_and_location() ! {
 entry := host.SharedRelay{id:'ab'.repeat(12),name:'Paseo',protocol:'websocket',url:'wss://example.invalid/ws'}
 mut app := Workshop{shared_relays:[entry],shared_status:{shared_status_key('',entry):'本机探测成功',shared_status_key('server',entry):'远端记录不可混入'}}
 root := ui2.screen(workbench_paper,shared_relays_view(&app,488))
 ui2.validate_element_tree(root)!
 assert audit_text(root).contains('本机探测成功')
 assert !audit_text(root).contains('远端记录不可混入')
 app.environment_id = 'server'
 app.server_snapshot = host.ServerSnapshot{connected:true,server_id:'server',relay_catalog:host.RelayCatalog{loaded:true,entries:[entry]}}
 remote := ui2.screen(workbench_paper,shared_relays_view(&app,488))
 ui2.validate_element_tree(remote)!
 assert audit_text(remote).contains('远端记录不可混入')
 assert !audit_text(remote).contains('本机探测成功')
}
