module main

import application_logs
import host
import ui2

fn test_application_log_source_switches_never_drop_application_scope() ! {
 mut app := Workshop{environment_id:'remote',workspace_log_application:'wechat',workspace_logs_follow:false,workspace_logs_text:'stale',remote_snapshot:host.RemoteSnapshot{workspace:host.RuntimeWorkspace{
  application_logs:{'wechat':application_logs.Snapshot{version:1,records:[
   application_logs.Record{app_id:'wechat',source:'console',message:'body-console'},
   application_logs.Record{app_id:'wechat',source:'request',message:'body-request'},
   application_logs.Record{app_id:'wechat',source:'relay',message:'body-relay'},
   application_logs.Record{app_id:'paseo',source:'console',message:'must-never-show'},
  ]}}
 }}}
 for source in ['stdout','runtime','relay','application'] {
  assert app.handle_workspace_event('workspace_source_'+source)
  assert app.workspace_log_application == 'wechat' && app.workspace_logs_text == ''
  root := ui2.screen(workbench_colors.paper,workspace_logs_view(mut app,488,740))
  ui2.validate_element_tree(root)!
  text := root.children.filter(it.id == 'workspace_logs')[0].text
  assert !text.contains('must-never-show') && !text.contains('stale')
  if source == 'stdout' { assert text.contains('body-console') && !text.contains('body-request') }
  if source == 'runtime' { assert text.contains('body-request') && !text.contains('body-console') }
  if source == 'relay' { assert text.contains('body-relay') && !text.contains('body-console') }
  if source == 'application' { assert text.contains('body-console') && text.contains('body-request') }
 }
}

fn test_old_or_failed_runtime_never_falls_back_to_process_output_for_an_app() {
 mut app := Workshop{workspace_log_application:'wechat',workspace_log_source:'stdout',snapshot:host.Snapshot{logs:'PASEO-PROCESS-OUTPUT'}}
 rows := workspace_logs_view(mut app,488,740)
 text := rows.filter(it.id == 'workspace_logs')[0].text
 assert !text.contains('PASEO-PROCESS-OUTPUT') && text.contains('不会显示其他应用')
}

fn test_unsupported_runtime_exposes_upgrade_without_mixed_output() ! {
	mut app := Workshop{workspace_log_application:'wechat',remote_snapshot:host.RemoteSnapshot{workspace:host.RuntimeWorkspace{application_logs_unsupported:true,application_logs_errors:{'wechat':'当前运行包尚不支持应用日志（HTTP 404）'}}},environment_id:'fixture'}
	root := ui2.screen(workbench_colors.paper,workspace_logs_view(mut app,488,740))
	ui2.validate_element_tree(root)!
	assert menu_button_enabled(root,'runtime')
}
