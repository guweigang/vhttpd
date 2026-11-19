module main

import host
import ui2

fn fixture_workspace() host.RuntimeWorkspace {
	return host.RuntimeWorkspace{
		known:        true
		applications: [
			host.RuntimeApplication{ id: 'bodytest', label: '体测智能助手', listeners: [host.ApplicationListener{ id: 'web', port: 19887, protocol: 'http' }] },
			host.RuntimeApplication{ id: 'paseo', label: 'Paseo', listeners: [host.ApplicationListener{ id: 'paseo', port: 19901, protocol: 'websocket' }] },
		]
	}
}

fn test_application_master_detail_keeps_both_selector_and_detail_visible() ! {
	for remote in [false,true] {
		mut app := Workshop{
			projects:[host.Project{name:'shared-runtime'}]
			environment_id:if remote {'fixture-server'} else {''}
			snapshot:host.Snapshot{pid:123,phase:.running,workspace:fixture_workspace()}
			remote_snapshot:host.RemoteSnapshot{workspace:fixture_workspace()}
			workspace_page:.applications
		}
		for width in [488.0,708.0] {
			for id in ['bodytest','paseo'] {
				assert app.handle_workspace_event('workspace_application_'+id)
				root := ui2.screen(workbench_colors.paper,runtime_workspace_view(mut app,width,740))
				ui2.validate_element_tree(root)!
				selector := root.children.filter(it.id=='workspace_app_selector')[0]
				detail := root.children.filter(it.id=='workspace_app_detail')[0]
				assert selector.frame.x+selector.frame.width < detail.frame.x
				assert selector.frame.y == detail.frame.y
				assert workspace_has_action(selector,'workspace_application_bodytest')
				assert workspace_has_action(selector,'workspace_application_paseo')
				assert workspace_has_action(detail,'workspace_app_logs_'+id)
				assert !workspace_has_action(root,'workspace_app_back')
				assert app.sequence==0 && app.selected==0
			}
		}
	}
}

fn test_workspace_application_navigation_never_changes_process_owner() ! {
	mut app := Workshop{ projects: [host.Project{ name: 'shared-runtime', config_path: '/fixture/vhttpd.toml' }], snapshot: host.Snapshot{ pid: 123, phase: .running, workspace: fixture_workspace() } }
	assert app.handle_workspace_event('workspace_application_paseo')
	assert app.workspace_application == 'paseo'
	assert app.snapshot.pid == 123 && app.selected == 0 && app.sequence == 0
	rows := runtime_workspace_view(mut app, 560, 740)
	root := ui2.screen(workbench_colors.paper, rows)
	for action in ['start', 'stop', 'restart', 'remote_restart'] {
		assert !workspace_has_action(root, action)
	}
	assert menu_button_enabled(root, 'workspace_app_logs_paseo')
	assert app.handle_workspace_event('workspace_app_logs_paseo')
	assert app.workspace_page == .logs && app.workspace_log_application == 'paseo'
	assert app.sequence == 0 && app.snapshot.pid == 123
}

fn test_workspace_pages_validate_local_and_remote_multiapp_trees() ! {
	for remote in [false, true] {
		mut app := Workshop{
			projects:        [host.Project{ name: 'shared-runtime', config_path: '/fixture/vhttpd.toml' }]
			environment_id:  if remote { 'fixture-server' } else { '' }
			remote_name:     'shared-remote'
			snapshot:        host.Snapshot{ phase: .running, pid: 123, workspace: fixture_workspace() }
			remote_snapshot: host.RemoteSnapshot{ connected: true, workspace: fixture_workspace(), instance: host.RemoteInstance{ ready: true, manual_restart: true } }
		}
		for page in [WorkspacePage.environment, .applications, .relay, .configuration, .logs] {
			app.workspace_page = page
			for width in [488.0, 708.0] {
				root := ui2.screen(workbench_colors.paper, runtime_workspace_view(mut app, width, 740))
				ui2.validate_element_tree(root)!
			}
		}
	}
}

fn test_workspace_log_pause_resume_and_context_reset() {
	mut app := Workshop{ workspace_logs_follow: true, workspace_log_application: 'paseo' }
	assert app.handle_workspace_event('workspace_logs_pause')
	assert !app.workspace_logs_follow
	assert app.handle_workspace_event('workspace_logs_follow')
	assert app.workspace_logs_follow && !app.workspace_logs_ready
	app.reset_workspace()
	assert app.workspace_log_application == '' && app.workspace_application == ''
	assert app.workspace_page == .environment
}

fn test_cancelled_environment_restart_never_dispatches_stop() {
	mut app := unsafe { workshop }
	saved := *app
	defer { unsafe { *app = saved } }
	unsafe {
		*app = Workshop{
			projects:        [host.Project{ name: 'fixture-runtime' }]
			snapshot:        host.Snapshot{ phase: .running, pid: 123 }
			confirm_restart: fn (_ string, _ string) bool {
				return false
			}
		}
	}
	handle_event('apply_restart')
	assert app.snapshot.phase == .running && !app.restart_after && app.sequence == 0
	select {
		_ := <-app.worker.commands {
			assert false, 'cancelled restart dispatched a lifecycle command'
		}
		else {
		}
	}
}

fn workspace_has_action(element ui2.Element, action string) bool {
	if element.id == action { return true }
	return element.children.any(workspace_has_action(it, action))
}

fn test_request_log_has_duration_and_correlation_id() {
	line := workspace_event_line(host.RuntimeEvent{
		kind:   'http.observation'
		fields: {
			'method':         'GET'
			'status':         '200'
			'duration_ms':    '8'
			'observation_id': 'http-123'
			'listener_id':    'web'
		}
	})
	assert line.contains('8 ms') && line.contains('http-123') && line.contains('listener=web')
}

fn test_paused_log_view_preserves_reading_content_while_new_events_arrive() {
	mut app := Workshop{
		workspace_logs_follow: false
		workspace_logs_text:   'previous readable record'
		snapshot:              host.Snapshot{
			workspace: host.RuntimeWorkspace{
				known:  true
				events: [host.RuntimeEvent{
					kind:    'new.request'
					at_unix: 123
					fields:  {
						'status': '200'
					}
				}]
			}
		}
	}
	paused := workspace_logs_view(mut app, 560, 740)
	assert paused.filter(it.id == 'workspace_logs')[0].text == 'previous readable record'
	assert app.handle_workspace_event('workspace_logs_follow')
	resumed := workspace_logs_view(mut app, 560, 740)
	assert resumed.filter(it.id == 'workspace_logs')[0].text.contains('new.request')
	assert app.handle_workspace_event('workspace_app_logs_bodytest')
	assert app.workspace_logs_text == ''
}

fn test_relay_library_returns_to_remote_runtime_workspace() {
	mut app := unsafe { workshop }
	saved := *app
	defer { unsafe { *app = saved } }
	unsafe { *app = Workshop{ environment_id: 'fixture-server', show_shared_relays: true } }
	handle_event('shared_close')
	assert app.show_remote && !app.show_shared_relays
}

fn test_return_from_package_settings_keeps_selected_runtime_in_each_location() {
	first := host.RemoteProfile{ id: 'first', name: 'First', server_id: 'fixture-server' }
	second := host.RemoteProfile{ id: 'second', name: 'Second', server_id: 'fixture-server' }
	mut app := Workshop{ remote_profiles: [first, second] }
	app.select_remote_profile(second)
	app.remote_id = 'fixture-server'
	app.open_environment_projects('fixture-server')
	assert app.remote_id == 'second'
	assert app.environment_id == 'fixture-server'
}

fn test_admin_request_focus_opens_local_logs_without_switching_process_owner() {
	mut app := Workshop{ selected: 2, environment_id: 'fixture-server', show_remote: true, show_takeover: true, snapshot: host.Snapshot{ pid: 123, phase: .running }, workspace_page: .applications, workspace_log_application: 'paseo', workspace_log_search: 'old search' }
	app.focus_request_logs()
	assert app.workspace_page == .logs && app.workspace_log_source == 'stdout'
	assert app.environment_id == '' && !app.show_remote && !app.show_takeover
	assert app.workspace_log_application == '' && app.workspace_log_search == ''
	assert app.selected == 2 && app.snapshot.pid == 123 && app.sequence == 0
}

// Validate complete windows, including the sidebar: page-only validation cannot
// catch a content action accidentally reusing a navigation control's ID.
fn test_every_workspace_page_validates_with_sidebar_in_both_locations() ! {
	mut app := unsafe { workshop }
	saved := *app
	defer { unsafe { *app = saved } }
	for remote in [false, true] {
		unsafe { *app = Workshop{ projects: [host.Project{ name: 'fixture-runtime', config_path: '/fixture/vhttpd.toml' }], snapshot: host.Snapshot{ phase: .running, pid: 123, workspace: fixture_workspace() } } }
		if remote {
			profile := host.RemoteProfile{ id: 'ab'.repeat(12), server_id: 'cd'.repeat(12), name: 'fixture-remote', ssh_host: 'fixture', token: 'fixture-admin' }
			app.remote_profiles = [profile]
			app.select_remote_profile(profile)
			app.remote_connected_form = app.remote_form()
			app.remote_snapshot = host.RemoteSnapshot{ profile_id: profile.id, connected: true, workspace: fixture_workspace(), instance: host.RemoteInstance{ ready: true } }
		}
		for page in [WorkspacePage.environment, .applications, .relay, .configuration, .logs] {
			app.workspace_page = page
			ui2.validate_element_tree(build_window())!
		}
		app.workspace_page = .relay
		assert app.handle_workspace_event('workspace_relay_library')
		assert app.show_shared_relays && !app.show_remote
	}
}
