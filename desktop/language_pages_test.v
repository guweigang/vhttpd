module main

import app_bundle
import host
import json2 as json
import os
import ui2

struct LanguagePage {
	name string
	rows []ui2.Element
}

struct LanguagePageIssue {
	page string
	language string
	width f64
	id string
	kind string
	text string
	required f64
	available f64
}

__global language_audit_index = 0
__global language_audit_width = 708.0

fn language_audit_window() ui2.Element {
	pages:=language_page_fixtures(language_audit_width)
	page:=pages[language_audit_index]
	content:=workbench_text_layout(localize_element(workbench_font_layout(ui2.screen(workbench_paper,page.rows))))
	return ui2.screen(workbench_paper,[
		ui2.dropdown('audit_page',page.name,pages.map(it.name),ui2.rect(16,12,300,36),ui2.BoxStyle{},ui2.TextStyle{size:14,font_family:workbench_ui_font}),
		button('audit_language',if workbench_language=='en' {'中文'} else {'English'},328,12,96,false,true),
		button('audit_width',if language_audit_width==708 {'488 px'} else {'708 px'},436,12,96,false,true),
		button('audit_next','Next →',544,12,140,true,true),
		ui2.scroll('audit_content',ui2.rect(16,64,language_audit_width,ui2.bounds().height-80),workbench_paper,content.children),
	])
}

fn language_audit_event(event string) {
	match event {
		'audit_page' {for i,page in language_page_fixtures(language_audit_width) {if page.name==ui2.text(event) {language_audit_index=i;break}}}
		'audit_language' {workbench_language=if workbench_language=='en' {'zh-CN'} else {'en'}}
		'audit_width' {language_audit_width=if language_audit_width==708 {488.0} else {708.0}}
		'audit_next' {language_audit_index=(language_audit_index+1)%language_page_fixtures(language_audit_width).len}
		else {return}
	}
	ui2.scroll_to_offset('audit_content',0)
	ui2.refresh()
}

fn language_page_fixtures(width f64) []LanguagePage {
	server := host.RemoteServer{id:'server',name:'Fixture server',ssh_host:'example.invalid',ssh_user:'test',ssh_port:22}
	profile := host.RemoteProfile{id:'bodytest',name:'bodytest',server_id:'server',runtime_id:'old',config_path:'/runtime/instances/bodytest/vhttpd.toml',ssh_host:'example.invalid'}
	live := host.RelayLiveStatus{known:true,checked_at:'12:00:00',data:host.RelayLiveData{carrier_count:1,open_channels:1,pending_frames:2,agents:[host.RelayLiveAgent{relay_id:'bodytest_database',state:'backoff',attempt:3}],channels:[host.RelayLiveChannel{id:'channel',route:'resource/database',open:true,buffered_len:10,returned_len:5}],diagnostics:host.RelayLiveDiagnostics{completed:12,failed:1}}}
	data := host.RuntimeWorkspace{known:true,checked_at:'12:00:00',relay:live,relays:[host.ApplicationItem{id:'bodytest_database',kind:'agent'}],websocket_known:true,websocket_connections:2,websocket_rooms:1,websocket_listeners:[host.WorkspaceWebSocketListener{listener_ids:['paseo'],active_connections:2,active_rooms:1}],applications:[host.RuntimeApplication{id:'wechat',label:'Bodytest',listeners:[host.ApplicationListener{id:'wechat',protocol:'http',host:'127.0.0.1',port:19887}],engines:[host.ApplicationItem{id:'main',kind:'vjsx'}],resources:[host.ApplicationItem{id:'wechat',kind:'db'}]},host.RuntimeApplication{id:'paseo',label:'Paseo',listeners:[host.ApplicationListener{id:'paseo',protocol:'websocket',host:'127.0.0.1',port:19901}]}]}
	preview := host.ApplicationDeploymentPreview{id:'preview',config_path:profile.config_path,files:[app_bundle.FileView{path:'apps/demo/main.mjs',action:'add'},app_bundle.FileView{path:'vhttpd.toml',action:'replace'}]}
	mut app := Workshop{workspace_logs_follow:false,projects:[host.Project{name:'bodytest',config_path:'/fixture/vhttpd.toml',workdir:'/fixture'}],remote_servers:[server],remote_profiles:[profile],runtime_info:host.RuntimeInfo{ready:true,version:'0.1.0',source:'App 内置'},runtime_checked:true,new_name:'my-app',new_parent:'/fixture',remote_id:'server',remote_name:server.name,remote_host:server.ssh_host,remote_user:server.ssh_user,remote_port:'22',runtime_server_id:'server',server_snapshot:host.ServerSnapshot{server_id:'server',server:server,connected:true,root:'/runtime',platform:'linux-amd64',runtimes:[host.RemoteRuntime{id:'old',version:'0.1.0',release_tag:'build-old'},host.RemoteRuntime{id:'new',version:'0.1.0',release_tag:'build-new'}],projects:[profile],deployment_preview:preview,upgrades:[host.RemoteRuntimeUpgrade{id:'previous',config_path:profile.config_path,phase:'completed',previous_id:'old',target_id:'new'}]},snapshot:host.Snapshot{phase:.running,pid:42,workspace:data,relay_live:live,recovery_history:[host.RecoveryVersionView{id:'v1',number:1,file_count:2,saved:true,latest:true,confirmed_at:'12:00:00'}]},shared_id:'ab'.repeat(12),shared_name:'Fixture Relay',shared_url:'wss://example.invalid/relay',shared_remote_id:'hub',shared_relays:[host.SharedRelay{id:'ab'.repeat(12),name:'Fixture Relay',url:'wss://example.invalid/relay'}],takeover_relay:'bodytest_database',takeover_app_id:'wechat',takeover_account:'fixture-account',component_target:'/fixture/vhttpd.toml',component_name:'demo',component_file:'/fixture/component.toml',history_before:'v1',history_after:'v2'}
	mut pages := []LanguagePage{}
	pages << LanguagePage{'new',new_project_view(app,0,width)}
	pages << LanguagePage{'runtime-local',runtime_local_view(app,width)}
	pages << LanguagePage{'runtime-download',runtime_downloads_view(app,width)}
	pages << LanguagePage{'servers',remote_servers_view(app,width)}
	pages << LanguagePage{'remote-connection',remote_instances_view(app,width)}
	pages << LanguagePage{'runtime-remote',runtime_remote_view(app,width)}
	app.server_runtime_selection='new';app.runtime_history_open=true
	pages << LanguagePage{'runtime-switch',runtime_remote_view(app,width)}
	app.runtime_create_open=true
	pages << LanguagePage{'runtime-create',runtime_remote_view(app,width)}
	app.runtime_create_open=false
	pages << LanguagePage{'component-install',component_installation_view(app,width)}
	pages << LanguagePage{'deployment',application_deployment_view(app,width)}
	pages << LanguagePage{'mcp',development_mcp_view(app,width)}
	pages << LanguagePage{'details',project_details_view(app,width)}
	pages << LanguagePage{'history',version_history_view(app,width)}
	pages << LanguagePage{'history-comparison',history_comparison_view(app,width)}
	pages << LanguagePage{'config-diff',config_diff_view(app,width)}
	pages << LanguagePage{'config-restore',config_rollback_view(app,width)}
	for page in [WorkspacePage.environment,.applications,.relay,.configuration,.logs] {
		app.workspace_page=page
		pages << LanguagePage{'workspace-'+page.str(),runtime_workspace_view(mut app,width,740)}
	}
	pages << LanguagePage{'shared-native',shared_relays_view(app,width)}
	app.shared_protocol='websocket'
	pages << LanguagePage{'shared-websocket',shared_relays_view(app,width)}
	app.shared_detail_tab='history'
	pages << LanguagePage{'shared-history',shared_relays_view(app,width)}
	app.shared_detail_tab='binding';app.shared_protocol='vhttpd'
	pages << LanguagePage{'shared-binding',shared_relays_view(app,width)}
	for active in [false,true] {
		app.snapshot=host.Snapshot{...app.snapshot,takeover_relay_id:'bodytest_database',takeover_status:host.TakeoverStatus{known:true,active:active,app_id:'wechat',accounts:['fixture-account'],checked_at:'12:00:00',local_in_flight:1}}
		pages << LanguagePage{'takeover-'+active.str(),takeover_view(app,width)}
		pages << LanguagePage{'relay-monitor-'+active.str(),relay_monitor_view(app,width)}
	}
	app.remote_auth='password'
	pages << LanguagePage{'server-password',remote_servers_view(app,width)}
	app.environment_id='server';app.remote_id='bodytest';app.remote_name='bodytest';app.remote_snapshot=host.RemoteSnapshot{connected:true,profile_id:'bodytest',workspace:data,instance:host.RemoteInstance{ready:true,manual_restart:true}}
	for page in [WorkspacePage.environment,.applications,.relay,.configuration,.logs] {
		app.workspace_page=page
		pages << LanguagePage{'remote-workspace-'+page.str(),runtime_workspace_view(mut app,width,740)}
	}
	app.snapshot=host.Snapshot{}
	pages << LanguagePage{'takeover-stopped',takeover_view(app,width)}
	app.component_target='bodytest'
	pages << LanguagePage{'remote-component-install',component_installation_view(app,width)}
	app.remote_id='';app.shared_id='';app.environment_id=''
	pages << LanguagePage{'server-empty',remote_servers_view(app,width)}
	pages << LanguagePage{'shared-empty',shared_relays_view(app,width)}
	app.creating=true
	pages << LanguagePage{'new-creating',new_project_view(app,0,width)}
	app.creating=false
	app.runtime_downloads=[host.RuntimeDownload{tag:'v1.0.0',channel:'stable',published_at:'2026-11-01T12:00:00Z'},host.RuntimeDownload{tag:'v1.1.0-rc1',channel:'development',published_at:'2026-11-01T12:00:00Z'}]
	pages << LanguagePage{'runtime-releases',runtime_downloads_view(app,width)}
	fields:=[host.ConfigFieldDiff{kind:'Pipeline',component:'main',field:'label',before:'old',after:'new',change:'修改'}]
	app.config_statuses={'/fixture/vhttpd.toml':host.ConfigStatus{pending:true,recovery_available:true,state:.unavailable,fields:fields,files:[host.ConfigFileDiff{path:'/fixture/vhttpd.toml',change:'修改',editable:true}]}}
	app.snapshot=host.Snapshot{phase:.running,pid:42,rollback_preview:host.RollbackPreview{id:'preview',available:true,version_label:'版本 1',message:'回滚预览已生成，尚未修改项目文件。',files:[host.RollbackFileView{path:'/fixture/vhttpd.toml',action:'恢复已生效内容与权限'}],fields:fields},history_comparison:host.HistoryComparison{before_id:'v1',after_id:'v2',before_label:'版本 1',after_label:'版本 2',fields:fields,message:'对比完成，当前项目配置未改动。'}}
	pages << LanguagePage{'config-diff-pending',config_diff_view(app,width)}
	pages << LanguagePage{'config-restore-preview',config_rollback_view(app,width)}
	pages << LanguagePage{'history-compared',history_comparison_view(app,width)}
	app.details=host.ProjectDetails{relays:[host.ProjectRelayInfo{id:'hub',mode:'hub',carrier:'websocket',endpoint:'ws://127.0.0.1/relay',node_id:'fixture',autostart:true}]}
	pages << LanguagePage{'details-with-relay',project_details_view(app,width)}
	app.component_target='/fixture/vhttpd.toml';app.component_prepared_file=app.component_file;app.component_prepared_name=app.component_name;app.component_sequence=7;app.component_action='preview'
	app.snapshot=host.Snapshot{...app.snapshot,component_preview:preview,component_result:host.OperationResult{sequence:7,target:app.component_target,action:'preview',preview_id:'preview'}}
	pages << LanguagePage{'component-preview',component_installation_view(app,width)}
	app.component_new=true
	pages << LanguagePage{'component-new',component_installation_view(app,width)}
	mut extra:=app
	extra.remote_id='new-server';extra.remote_name='';extra.remote_host='';extra.remote_user='';extra.remote_port='';extra.remote_auth='key'
	pages << LanguagePage{'server-new',remote_servers_view(extra,width)}
	extra.remote_id='server';extra.remote_name='Fixture server';extra.remote_host=server.ssh_host
	extra.server_snapshot=host.ServerSnapshot{...extra.server_snapshot,connected:false,host_key:host.RemoteHostKey{id:'challenge',algorithm:'ED25519',fingerprint:'SHA256:fixture'}}
	pages << LanguagePage{'server-fingerprint',remote_servers_view(extra,width)}
	extra.runtime_info=host.RuntimeInfo{};extra.runtime_checked=true
	pages << LanguagePage{'runtime-unavailable',runtime_local_view(extra,width)}
	for known in [false,true] {
		extra.environment_id='';extra.snapshot=host.Snapshot{workspace:host.RuntimeWorkspace{known:known}}
		for page in [WorkspacePage.applications,.relay,.logs] {
			extra.workspace_page=page
			pages << LanguagePage{'workspace-empty-'+known.str()+'-'+page.str(),runtime_workspace_view(mut extra,width,740)}
		}
	}
	return pages
}

fn language_scan_page(e ui2.Element, page string, language string, width f64, mut issues []LanguagePageIssue) {
	if e.hidden {return}
	for text in [e.text,e.placeholder,e.accessibility_label] {
		if language=='en' && text.runes().any(it>=0x4e00 && it<=0x9fff) {
			issues << LanguagePageIssue{page:page,language:language,width:width,id:e.id,kind:'untranslated',text:text}
		}
	}
	if e.kind==.text_field && e.text=='' && e.placeholder!='' && e.frame.width>20 {
		measured:=workbench_label_width(e.placeholder,e.text_style)
		if measured>e.frame.width-12+1 {issues << LanguagePageIssue{page:page,language:language,width:width,id:e.id,kind:'placeholder-width',text:e.placeholder,required:measured,available:e.frame.width-12}}
	}
	if e.kind==.label && e.text!='' && e.frame.width>0 {
		measured:=ui2.measure_layout_text(e.text,ui2.TextStyle{...e.text_style,lines:10000},1000000) or {panic(err)}
		if measured.width>e.frame.width-2+1 {
			issues << LanguagePageIssue{page:page,language:language,width:width,id:e.id,kind:'width',text:e.text,required:measured.width,available:e.frame.width-2}
		} else if e.text_style.lines>1 && measured.height>e.frame.height+2 {
			issues << LanguagePageIssue{page:page,language:language,width:width,id:e.id,kind:'height',text:e.text,required:measured.height,available:e.frame.height}
		}
	}
	for child in e.children {language_scan_page(child,page,language,width,mut issues)}
}

fn test_page_language_and_text_bounds_audit() ! {
	previous:=workbench_language
	defer {workbench_language=previous}
	$if macos {
		fonts:=os.join_path(@VMODROOT,'desktop/bin/vhttpd-workbench.app/Contents/Resources/fonts')
		for _,path in load_workbench_fonts(fonts)! {register_workbench_font(path)!}
	}
	if os.getenv('VHTTPD_LANGUAGE_AUDIT_UI')=='1' {
		workbench_language='en'
		ui2.run_window('Language pages QA',740,880,language_audit_window,language_audit_event)
		return
	}
	mut issues:=[]LanguagePageIssue{}
	mut count:=0
	for language in ['zh-CN','en'] {
		workbench_language=language
		for width in [488.0,708.0] {
			for page in language_page_fixtures(width) {
				root:=workbench_text_layout(localize_element(workbench_font_layout(ui2.screen(workbench_paper,page.rows))))
				language_scan_page(root,page.name,language,width,mut issues)
				count++
			}
		}
	}
	path:=os.getenv_opt('VHTTPD_LANGUAGE_AUDIT_REPORT') or {os.join_path(os.temp_dir(),'vhttpd-language-pages.json')}
	os.write_file(path,json.encode(issues, prettify: true))!
	println('Language page audit: ${count} pages; ${issues.len} findings; ${path}')
	if os.getenv('VHTTPD_LANGUAGE_AUDIT_STRICT')!='0' {assert issues.len==0}
}
