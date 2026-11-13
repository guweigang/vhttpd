@[has_globals]
module main

import host
import devmcp
import os
import time
import ui2

#include <stdlib.h>

fn C.atexit(fn ()) int

@[heap]
struct Workshop {
mut:
	keyboard_navigation_focus string
	desktop_update_open bool
	desktop_update_busy bool
	desktop_update_checked bool
	desktop_update_settings ui2.SettingsState
	desktop_update_job host.RuntimeJob
	desktop_update_result DesktopUpdateResult
	desktop_update_results chan DesktopUpdateResult = chan DesktopUpdateResult{cap: 1}
	show_development                 bool
	development_apps                 []host.DevelopmentApplication
	development_application          string
	development_project              host.Project
	development_catalog_project      host.Project
	development_relay_choices        []host.SharedRelay
	development_relay_id             string
	development_relay_url            string
	development_remote_hub           host.McpHubTarget
	development_relay_catalog_serial u64
	development_runtime_generation   u64
	development_pending              bool
	development_results              chan DevelopmentConnectionResult = chan DevelopmentConnectionResult{cap: 1}
	component_adopt_engines          []string
	component_installation_id        string
	component_new                    bool
	component_template               string = 'vjsx-http'
	component_port                   string = '0'
	development_message              string
	development_service              &devmcp.Service          = unsafe { nil }
	confirm_restart fn (string, string) bool = ui2.confirm
	workspace_page WorkspacePage
	workspace_application string
	workspace_log_application string
	workspace_log_search string
	workspace_log_source string
	workspace_logs_follow bool = true
	workspace_logs_ready bool
	workspace_logs_offset f64
	workspace_logs_text string
	workspace_logs_layout_pending bool
	declared_menus []ui2.Menu
	pending_form_focus string
	owner_pid int
	show_component_install bool
	component_file string
	component_name string
	component_target string
	component_error string
	component_preview_before string
	component_prepared_file string
	component_sequence u64
	component_action string
	component_operation_id string
	component_prepared_name string
	show_deployment bool
	deployment_local int
	deployment_remote string
	show_servers bool
	server_sequence u64
	remote_server_id string
	remote_auto_open bool
	remote_edit_connection bool
	remote_servers []host.RemoteServer
	server_worker host.ServerWorker
	server_snapshot host.ServerSnapshot
	server_busy bool
	runtime_server_id string
	environment_id string
	environment_runtime_selection map[string]string
	environment_menu ui2.DropdownMenuState
	show_runtime_downloads bool
	runtime_catalog_busy bool
	runtime_catalog_error string
	runtime_catalog_channel string = 'all'
	runtime_catalog_ref string
	runtime_selected_tag string
	runtime_downloads []host.RuntimeDownload
	runtime_catalog_job host.RuntimeJob
	runtime_catalog_results chan RuntimeCatalogResult = chan RuntimeCatalogResult{cap: 1}
	server_instance_name string = 'hello-vjsx'
	server_web_port string = '19881'
	server_admin_port string = '2018'
	server_upgrade_project string
	runtime_history_open bool
	runtime_create_open bool
	runtime_operation_sequence u64
	runtime_operation_server string
	runtime_form_error string
	runtime_upgrade_before []string
	server_runtime_selection string
	server_template int = 2
	server_created_id string
	server_discovery_revision u64
	remote_pending_connect string
	remote_sequence u64
	show_remote bool
	remote_worker host.RemoteWorker
	remote_connected_form host.RemoteProfile
	remote_snapshot host.RemoteSnapshot
	remote_profiles_error string
	remote_profiles []host.RemoteProfile
	remote_id string
	remote_name string
	remote_host string
	remote_user string
	remote_port string
	remote_admin_port string
	remote_identity string
	remote_auth string = 'key'
	remote_password string
	remote_token string
	remote_message string
	config_statuses      map[string]host.ConfigStatus
	projects             []host.Project
	selected             int
	binary               string
	show_runtime         bool
	runtime_info         host.RuntimeInfo
	runtime_checked      bool
	runtime_busy         bool
	runtime_error        bool
	runtime_message      string
	runtime_resume_start bool
	runtime_job          host.RuntimeJob
	runtime_results      chan RuntimeResult = chan RuntimeResult{cap: 1}
	brand_mark           string
	registry             string
	worker               host.Worker
	snapshot             host.Snapshot
	notice               string
	request_open         bool
	pending_project      int = -1
	restart_after        bool
	worker_started       bool
	refresh_stop         chan bool = chan bool{cap: 1}
	quitting             bool
	sequence             u64
	history_custom_base  bool
	show_history_diff    bool
	show_history         bool
	history_before       string
	history_after        string
	rollback_version     string
	show_rollback        bool
	show_config_diff     bool
	show_details         bool
	details              host.ProjectDetails
	details_error        string
	new_project          bool
	creating             bool
	new_name             string
	new_parent           string
	new_template         int
	new_auto_start       bool = true
	new_error            string
	creation_results     chan CreationResult = chan CreationResult{cap: 1}
	show_takeover bool
	show_relay_monitor bool
	takeover_binding_id              string
	takeover_relay string
	takeover_app_id string
	takeover_account string
	show_shared_relays   bool
	shared_detail_tab    string = 'connection'
	shared_relays        []host.SharedRelay
	shared_protocol string = 'vhttpd'
	shared_scope string
	relay_logs_next i64
	shared_catalog_pending bool
	shared_test_id string
	shared_test_host string
	shared_test_form host.SharedRelay
	shared_test_scope string
	shared_status map[string]string
	shared_probe_logs []string
	shared_id            string
	shared_name          string
	shared_url           string
	shared_token         string
	shared_remote_id     string
	shared_db_local      string = 'wechat'
	shared_db_remote     string = 'db/wechat'
	shared_db_route      string = 'resource/database'
	shared_message       string
	shared_testing       bool
	shared_use_pending   bool
	shared_results       chan host.RelayProbeResult = chan host.RelayProbeResult{cap: 1}
}

const workshop = &Workshop{}

fn main() {
	if os.args.len == 2 && os.args[1] == '--version' && os.getenv('VHTTPD_SSH_ASKPASS') != '1' {
		println('vhttpd Desktop ' + desktop_version)
		return
	}
	if os.getenv('VHTTPD_SSH_ASKPASS') == '1' {
		host.run_remote_askpass() or { exit(1) }
		return
	}
 $if windows {
  if '--windows-ssh-smoke' in os.args {
   host.run_windows_ssh_smoke() or {
				if result := os.getenv_opt('VHTTPD_WINDOWS_SMOKE_RESULT') {
					os.write_file(result, 'FAIL: ' + err.msg()) or {}
				}
    exit(1)
   }
			if result := os.getenv_opt('VHTTPD_WINDOWS_SMOKE_RESULT') {
				os.write_file(result, 'PASS') or {}
			}
   return
  }
 }
	$if !macos && !linux && !windows {
		eprintln('当前交付 macOS 和 Linux；Windows 适配尚未完成。')
		exit(1)
	}
	root := os.real_path(os.join_path(os.dir(@FILE), '..'))
	if '--runtime-smoke' in os.args {
		run_runtime_smoke(root) or {
			eprintln(err)
			exit(1)
		}
		return
	}
	if '--shared-relay-smoke' in os.args {
		run_shared_relay_smoke(root) or {
			eprintln(err)
			exit(1)
		}
		return
	}
	if '--status-smoke' in os.args || '--persistent-status-smoke' in os.args {
		run_status_smoke(root) or {
			eprintln(err)
			exit(1)
		}
		return
	}
	if '--font-smoke' in os.args {
		run_font_smoke() or {
			eprintln(err)
			exit(1)
		}
		return
	}
	if '--smoke' in os.args {
		run_smoke(root) or {
			eprintln(err)
			exit(1)
		}
		return
	}
	mut app := unsafe { workshop }
	app.owner_pid = os.getpid()
	initialize_language()
	initialize_appearance()
	configure_workbench_fonts() or { app.notice = err.msg() }
	app.binary = host.selected_runtime(os.executable(), root) or {
		app.notice = err.msg()
		host.workbench_binary(os.executable(), root)
	}
	$if !linux {
		app.inspect_binary(app.binary, false)
	}
	app.brand_mark = host.workbench_brand_mark(os.executable(), root)
	app.registry = os.getenv_opt('VHTTPD_DESKTOP_REGISTRY') or { os.join_path(host.workbench_data_dir(), 'projects.json') }
	// Existing checkout users keep their registrations when upgrading to the app.
	legacy_registry := os.join_path(root, 'desktop', '.local', 'projects.json')
	if os.getenv('VHTTPD_DESKTOP_REGISTRY') == '' && !os.exists(app.registry) && os.is_file(legacy_registry) {
		legacy := host.load_projects(legacy_registry, []) or { []host.Project{} }
		if legacy.len > 0 {
			host.save_projects(app.registry, legacy) or { app.notice = '旧项目登记迁移失败：${err}。可通过导入项目重新登记。' }
		}
	}
	defaults := []host.Project{}
	app.projects = host.load_projects(app.registry, defaults) or {
		app.notice = '项目登记读取失败：${err}。请保留登记文件，通过导入项目恢复。'
		defaults
	}
	app.shared_relays = host.load_shared_relays() or {
		app.notice = '共享连接库读取失败，请保留 shared-relays.json，修复后重新打开工作台。'
		app.shared_message = app.notice
		[]host.SharedRelay{}
	}
	app.reload_remote_profiles()
	app.remote_worker = host.new_remote_worker()
	app.remote_servers = host.load_remote_servers() or {
		app.notice = err.msg()
		[]host.RemoteServer{}
	}
	app.server_worker = host.new_server_worker()
	app.worker = host.new_worker()
	app.worker_started = true
	$if !linux {
		if app.projects.len > 0 { app.select_current() }
	}
	C.atexit(cleanup)
	$if windows {
		C.vhttpd_workbench_prepare_windows_display()
	}
	app.refresh_workbench_menus(ui2.screen(workbench_colors.paper, []))
	$if !windows {
		configure_workbench_tray(app.brand_mark, root)
	}
	$if windows {
		spawn workbench_refresh_loop(app.refresh_stop, ui2.request_poll_refresh)
	} $else {
		spawn workbench_refresh_loop(app.refresh_stop, ui2.request_refresh)
	}
	ui2.on_key(workbench_key)
	ui2.on_key_event(workbench_physical_key)
	ui2.on_window_ready(configure_workbench_window)
	$if windows {
  scale := windows_display_scale()
		ui2.run_window(ui_text('vhttpd · 本地工作台'), int(980 * scale), int(740 * scale), build_window, handle_event)
 } $else $if linux {
		configure_linux_fonts()
		ui2.run_window_with_options(ui2.WindowOptions{ title: ui_text('vhttpd · 本地工作台'), width: 980, height: 740, min_width: 760, min_height: 660 }, build_window, handle_event)
	} $else {
		ui2.run_window(ui_text('vhttpd · 本地工作台'), 980, 740, build_window, handle_event)
	}
	cleanup()
}

fn cleanup() {
	mut app := unsafe { workshop }
	// Graphics drivers may fork while initializing. Inherited atexit hooks
	// must never send commands to the parent's copied worker channels.
	if app.owner_pid != os.getpid() || !app.worker_started || app.quitting { return }
	app.quitting = true
	if app.desktop_update_busy {
		select {
			app.desktop_update_job.cancel <- true {
	}
			else {
			}
		}
	}
	if !isnil(app.development_service) { app.development_service.close() }
	app.refresh_stop <- true
	select {
		app.runtime_catalog_job.cancel <- true {
		}
		else {
		}
	}
	if app.runtime_busy {
		select {
			app.runtime_job.cancel <- true {
			}
			else {
			}
		}
		select {
			_ := <-app.runtime_results {
			}
			3 * time.second {
			}
		}
	}
	app.remote_worker.commands <- host.RemoteCommand{action: .shutdown}
	select {
		_ := <-app.remote_worker.done {
		}
		5 * time.second {
		}
	}
	select {
		app.server_worker.job.cancel <- true {
		}
		else {
		}
	}
	app.server_worker.commands <- host.ServerCommand{action: .shutdown}
	select {
		_ := <-app.server_worker.done {
		}
		5 * time.second {
		}
	}
	app.worker.commands <- host.Command{ action: .shutdown }
	select {
		_ := <-app.worker.done {
		}
		10 * time.second {
			eprintln('工作台退出收尾超时，请检查本次实例。')
		}
	}
}

fn poll_worker() {
	mut app := unsafe { workshop }
	if app.quitting { return }
	app.poll_desktop_update()
	// Consume worker previews before accepting the next MCP apply request.
	app.poll_server()
	app.poll_development()
	if app.component_new && app.component_action == 'install' {
		_, _, tone := app.component_feedback()
		if tone == 'good' { app.workspace_application = app.component_name }
	}
	select {
		status := <-app.remote_worker.snapshots {
			if status.sequence >= app.remote_sequence && app.remote_pending_connect == '' {
				app.remote_snapshot = status
			}
		}
		else {
		}
	}
	if app.remote_auto_open && app.remote_snapshot.connected && !app.remote_snapshot.busy && app.remote_snapshot.profile_id == app.remote_id {
		app.remote_auto_open = false
		app.send_remote(.open_admin)
	}
	app.poll_runtime()
	app.poll_runtime_catalog()
	app.poll_relay_process_logs()
	app.poll_creation()
	select {
		result := <-app.shared_results {
			app.shared_testing = false
			line := time.now().format_ss() + ' · ' + app.shared_test_host + ' · ' + result.stage + ' · ' + result.message + ' (${result.elapsed_ms} ms)'
			if app.shared_status.len >= 512 { app.shared_status.clear() }
			app.shared_status[shared_status_key(app.shared_test_scope, app.shared_test_form)] = line
			app.shared_probe_logs << app.shared_test_scope + ':' + app.shared_test_id + ' · ' + line
			if app.shared_probe_logs.len > 100 { app.shared_probe_logs.delete(0) }
			if app.shared_test_scope == app.environment_id && app.shared_test_id == app.shared_id && app.shared_test_form == app.shared_form() {
				app.shared_message = line
			}
		}
		else {
		}
	}
	select {
		s := <-app.worker.snapshots {
			if s.sequence < app.sequence {
				return
			}
			if s.project != '' {
				if !app.projects.any(it.config_path == s.project) {
					if !isnil(app.development_service) && app.development_service.selection().source_workspace && app.development_service.selection().project.config_path == s.project {
						app.projects << app.development_service.selection().project
					} else if project := host.project_from_file(s.project, '') {
						mut projects := app.projects.clone()
						projects << project
						host.save_projects(app.registry, projects) or { app.notice = err.msg() }
						app.projects = projects
					}
				}
				for i, project in app.projects {
					if project.config_path == s.project { app.selected = i }
				}
				app.config_statuses[s.project] = s.config_status
			}
			if s.log_focus_serial > app.snapshot.log_focus_serial {
				app.focus_request_logs()
				app.show_details = false
				app.show_history = false
				app.show_config_diff = false
				app.show_history_diff = false
				app.show_rollback = false
				bring_workbench_forward()
			}
			app.snapshot = s
			if app.shared_use_pending {
				app.shared_message = s.message
				app.shared_use_pending = false
			}
			if app.pending_project >= 0 && s.pid == 0 && s.phase !in [.starting, .stopping] {
				index := app.pending_project
				app.pending_project = -1
				app.activate_project(index)
			}
			app.continue_lifecycle(s)
		}
		else {
		}
	}
}

// The host owns background polling. ui2 only schedules a rebuild on the UI
// thread; worker results are consumed there, never by this waiting thread.
fn workbench_refresh_loop(stop chan bool, request_refresh fn ()) {
	for {
		select {
			_ := <-stop { return }
			500 * time.millisecond { request_refresh() }
		}
	}
}

fn (mut app Workshop) continue_lifecycle(s host.Snapshot) {
	if s.phase == .running && app.request_open {
		app.request_open = false
		app.send(.open_admin)
	}
	if s.phase == .failed || (s.pid == 0 && s.message != '' && s.phase != .running) {
		app.request_open = false
	}
	// Clear the old stop result before scheduling the new instance's login.
	if s.phase == .stopped && app.restart_after {
		app.restart_after = false
		app.launch_with_browser(true)
	}
}

fn (mut app Workshop) send(action host.Action) {
	next_sequence := app.sequence + 1
	select {
		app.worker.commands <- host.Command{ action: action, sequence: next_sequence } {
			app.sequence = next_sequence
		}
		else {
			app.notice = '操作正在处理，请稍候。'
		}
	}
}

fn (mut app Workshop) select_current() {
	app.sequence++
	app.worker.commands <- host.Command{ action: .select_project, sequence: app.sequence, project: app.projects[app.selected] }
}

fn (mut app Workshop) launch() {
	app.launch_with_browser(true)
}

fn (mut app Workshop) launch_with_browser(open_browser bool) {
	if app.projects.len == 0 || app.snapshot.pid != 0 || app.snapshot.phase in [
		.starting,
		.stopping,
	] {
		return
	}
	if app.runtime_busy || (app.runtime_checked && !app.runtime_info.ready) {
		app.runtime_server_id = ''
		app.show_runtime_downloads = false
		app.show_runtime = true
		app.show_shared_relays = false
		app.runtime_resume_start = true
		if app.snapshot.project != app.projects[app.selected].config_path { app.select_current() }
		return
	}
	app.notice = ''
	app.request_open = open_browser
	app.snapshot = host.Snapshot{ phase: .starting, message: '正在读取配置…' }
	app.sequence++
	app.worker.commands <- host.Command{
		sequence: app.sequence
		action:   .start
		project:  app.projects[app.selected]
		binary:   app.binary
	}
}

fn handle_event(event string) {
	mut navigation_app := unsafe { workshop }
	navigation_app.keyboard_navigation_focus = ''
	if event == 'tray:open' {
		bring_workbench_forward()
		return
	}
	if event == 'tray:updates' {
		bring_workbench_forward()
		handle_workbench_menu('menu:desktop_updates')
		return
	}
	mut development_app := unsafe { workshop }
	if development_app.handle_development_event(event) {
		ui2.refresh()
		return
	}
	if handle_workbench_menu(event) { return }
	$if windows {
		if handle_windows_field_event(event) { return }
	}
	mut app := unsafe { workshop }
	if app.handle_desktop_update_event(event) { return }
	if event == 'form_submit' {
		submit_active_form()
		return
	}
	defer {
		focus_id := match event {
			'new', 'empty_new' {
				if app.environment_id == '' { 'new_name' } else { 'server_instance_name' }
			}
			'server_new' { 'server_name' }
			'remote_new' { 'remote_name' }
			'shared_new' { 'shared_name' }
			'server_password_mode' { 'server_password' }
			'remote_auth_password' { 'remote_password' }
			else { '' }
		}
		if focus_id != '' && !app.creating {
			ui2.focus(focus_id)
			$if linux {
				// The immediate renderer registers new fields after this event.
				app.pending_form_focus = if ui2.focused_id() == focus_id { '' } else { focus_id }
			}
		}
	}
	if app.creating { return }
	if app.handle_workspace_event(event) {
		ui2.refresh()
		return
	}
	if event.starts_with('project_') || event.starts_with('remote_select_') {
		app.reset_workspace()
	}
	if event.starts_with('project_') {
		app.takeover_binding_id = ''
		app.takeover_relay = ''
		app.takeover_app_id = ''
		app.takeover_account = ''
	}
	if event in ['server_home', 'server_back', 'shared_relays', 'runtime', 'new', 'import'] || event.starts_with('project_') {
		app.show_takeover = false
		app.show_relay_monitor = false
		app.new_project = false
	}
	if app.handle_component_event(event) {
		ui2.refresh()
		return
	}
	if event in ['server_home', 'runtime', 'new', 'import'] || event.starts_with('project_') || event.starts_with('remote_select_') {
		app.show_component_install = false
	}
	if app.handle_deployment_event(event) {
		ui2.refresh()
		return
	}
	if event in ['server_home', 'runtime', 'new', 'import'] || event.starts_with('project_') {
		app.show_deployment = false
	}
	if app.handle_environment_event(event) {
		ui2.refresh()
		return
	}
	if app.handle_server_event(event) {
		ui2.refresh()
		return
	}
	if app.handle_remote_event(event) {
		ui2.refresh()
		return
	}
	if app.handle_runtime_event(event) {
		app.show_remote = false
		ui2.refresh()
		return
	}
	if app.handle_takeover_event(event) {
		ui2.refresh()
		return
	}
	if app.handle_shared_relay_event(event) {
		app.show_runtime = false
		if event == 'shared_close' {app.show_remote = app.environment_id != ''}
		ui2.refresh()
		return
	}
	if event == 'new' || event == 'import' || event.starts_with('project_') || event == 'runtime' {
		app.show_remote = false
	}
	match event {
		'new', 'empty_new' {
			app.show_shared_relays = false
			app.show_runtime = false
			app.show_new_project()
		}
		'new_cancel' {
			app.new_project = false
			app.new_error = ''
		}
		'new_name' {
			app.new_name = ui2.text('new_name')
			app.new_error = ''
		}
		'new_parent' {
			app.new_parent = ui2.text('new_parent')
			app.new_error = ''
		}
		'new_auto_start' { app.new_auto_start = !app.new_auto_start }
		'new_choose_parent' {
			// Zenity treats a filename without a trailing slash as a proposed
			// file, even for a folder picker. Pass an actual directory path.
			parent := if os.is_dir(app.new_parent) && !app.new_parent.ends_with(os.path_separator) {
				app.new_parent + os.path_separator
			} else {
				app.new_parent
			}
			dirs := ui2.open_folder_dialog(
				title:     ui_text('选择项目存放目录')
				directory: parent
			)
			if dirs.len > 0 {
				app.new_parent = dirs[0]
				app.new_error = ''
			}
		}
		'new_submit' { app.submit_new_project() }
		'details' {
			app.show_shared_relays = false
			app.inspect_current_project()
		}
		'details_refresh' { app.inspect_current_project() }
		'details_close' { app.show_details = false }
		'edit_config' {
			if app.projects.len > 0 {
				host.open_text_file(app.projects[app.selected].config_path) or { app.notice = err.msg() }
			}
		}
		'edit_source' {
			if app.projects.len > 0 {
				info := host.project_details(app.projects[app.selected]) or {
					app.notice = '请先修复项目配置。'
					return
				}
				host.open_text_file(info.entry) or { app.notice = err.msg() }
			}
		}
		'start' { app.launch() }
		'stop' {
			app.restart_after = false
			app.send(.stop)
		}
		'force' {
			if ui_confirm('强制停止', '仅强制结束此工作台启动的实例及其进程组。未完成的工作可能中断。') {
				app.restart_after = false
				app.send(.force_stop)
			}
		}
		'restart', 'apply_restart' {
			if app.snapshot.phase != .running { return }
			if !app.confirm_restart('重启运行环境', '将重启当前 vhttpd 进程，其中全部应用会短暂中断。是否继续？') {
				return
			}
			app.show_config_diff = false
			app.show_history = false
			app.show_history_diff = false
			app.show_rollback = false
			app.show_details = false
			app.notice = ''
			app.restart_after = true
			app.send(.stop)
			app.snapshot = host.Snapshot{ ...app.snapshot, phase: .stopping }
		}
		'preview_rollback' { app.preview_selected_version(app.rollback_version) }
		'history_open' { app.open_version_history() }
		'history_close' {
			app.show_history = false
			app.show_config_diff = false
			app.show_history_diff = false
		}
		'history_list' { app.show_history_diff = false }
		'history_compare' { app.compare_selected_versions() }
		'history_preview' { app.preview_selected_version(app.history_after) }
		'rollback_close' {
			app.show_rollback = false
			app.show_history_diff = false
		}
		'restore_rollback' { app.confirm_config_restore() }
		'config_diff' { app.show_config_diff = true }
		'config_diff_close' { app.show_config_diff = false }
		'check_config' { app.send(.check_config) }
		'admin' { app.send(.open_admin) }
		'open_app' {
			if app.snapshot.phase == .running && app.snapshot.app_url != '' {
				host.open_local(app.snapshot.app_url) or { app.notice = err.msg() }
			}
		}
		'clear' { app.send(.clear_logs) }
		'all_logs' {
			app.workspace_logs_follow = true
			app.workspace_logs_ready = false
			app.workspace_logs_text = ''
			app.send(.show_all_logs)
		}
		'folder' {
			if app.projects.len > 0 {
				host.open_local(os.dir(app.projects[app.selected].config_path)) or { app.notice = err.msg() }
			}
		}
		'import', 'empty_import' { app.import_project() }
		'binary' {
			if app.runtime_busy || app.snapshot.pid != 0 || app.snapshot.phase in [
				.starting,
				.stopping,
			] {
				return
			}
			files := ui2.open_file_dialog(
				title:     ui_text('选择 vhttpd 可执行文件')
				directory: os.dir(app.binary)
			)
			if files.len > 0 && app.snapshot.pid == 0 && !app.runtime_busy {
				app.inspect_binary(os.real_path(files[0]), true)
			}
		}
		'quit', 'tray:quit' {
			if ui2.tray_visible() { ui2.remove_tray() }
			cleanup()
			ui2.quit()
		}
		else {
			if event.starts_with('history_before_') {
				app.history_before = event.all_after('history_before_')
				app.history_custom_base = true
			} else if event.starts_with('history_view_') {
				app.history_after = event.all_after('history_view_')
				if !app.history_custom_base {
					for i, version in app.snapshot.recovery_history {
						if version.id == app.history_after {
							app.history_before = app.snapshot.recovery_history[if i + 1 < app.snapshot.recovery_history.len {
								i + 1
							} else {
								i
							}].id
							break
						}
					}
				}
				app.compare_selected_versions()
			} else if event.starts_with('history_restore_') {
				app.history_after = event.all_after('history_restore_')
				app.preview_selected_version(app.history_after)
			} else if event.starts_with('config_edit_') {
				app.open_config_diff_source(event.all_after('config_edit_').int())
			} else if event.starts_with('new_template_') {
				index := event.all_after('new_template_').int()
				if index >= 0 && index < host.project_templates().len { app.new_template = index }
			} else if event.starts_with('project_') {
				app.choose_project(event.all_after('project_').int())
			}
		}
	}
	ui2.refresh()
}

fn (mut app Workshop) activate_project(index int) {
	if index < 0 || index >= app.projects.len { return }
	app.show_details = false
	app.show_config_diff = false
	app.show_rollback = false
	app.show_history = false
	app.history_before = ''
	app.history_after = ''
	app.rollback_version = ''
	app.selected = index
	app.runtime_resume_start = false
	app.snapshot = host.Snapshot{}
	app.notice = ''
	app.select_current()
}

fn (mut app Workshop) choose_project(index int) {
	app.set_environment('')
	if app.new_project || index < 0 || index >= app.projects.len { return }
	if index == app.selected && app.pending_project < 0 { return }
	app.request_open = false
	app.restart_after = false
	if app.snapshot.pid > 0 || app.snapshot.phase in [.starting, .stopping] {
		app.pending_project = index
		app.notice = '正在停止当前实例，随后切换到 ${app.projects[index].name}…'
		if app.snapshot.phase != .stopping {
			app.send(.stop)
			app.snapshot = host.Snapshot{ ...app.snapshot, phase: .stopping }
		}
	} else {
		app.pending_project = -1
		app.activate_project(index)
	}
}

fn (mut app Workshop) import_project() {
	if app.new_project { return }
	if app.snapshot.pid != 0 || app.snapshot.phase in [.starting, .stopping] {
		app.notice = '请先停止实例，再导入和切换项目。'
		return
	}
	files := ui2.open_file_dialog(
		title:   ui_text('选择 vhttpd TOML 配置')
		filters: [ui2.FileDialogFilter{
			name:       'vhttpd 配置'
			extensions: ['toml']
		}]
	)
	if files.len == 0 { return }
	// Existing v2 projects may resolve relative entries from a chosen working
	// directory. Do not silently assume the config's directory is that root.
	dirs := ui2.open_folder_dialog(
		title:     ui_text('选择项目工作目录')
		directory: os.dir(files[0])
	)
	if dirs.len == 0 { return }
	project := host.project_from_file(files[0], dirs[0]) or {
		app.notice = err.msg()
		return
	}
	host.inspect_project(project) or {
		app.notice = '配置检查失败：${err}'
		return
	}
	for i, existing in app.projects {
		if existing.config_path == project.config_path {
			app.selected = i
			app.snapshot = host.Snapshot{}
			app.notice = '该项目已经登记，已选中。'
			app.select_current()
			return
		}
	}
	mut next := app.projects.clone()
	next << project
	host.save_projects(app.registry, next) or {
		app.notice = '登记保存失败：${err}'
		return
	}
	app.projects = next
	app.selected = next.len - 1
	app.snapshot = host.Snapshot{}
	app.notice = '项目已导入，配置文件未修改。'
	app.select_current()
}

fn workbench_detail_font() string {
	// The custom backend's mono fallback has no CJK glyphs. Use the shipped
	// primary face so error messages and redacted diffs remain readable.
	$if linux { return '' }
 $if windows { return 'Consolas' }
	return 'Menlo'
}

fn label(id string, text string, x f64, y f64, width f64, size f64, color u32) ui2.Element {
	height := if size * 1.5 + 4 > 25 { size * 1.5 + 4 } else { 25.0 }
	return ui2.label(id, text, ui2.rect(x, y, width, height), ui2.TextStyle{ size: size, color: color })
}

// Keep text independent of NSButton's disabled-title drawing, while retaining
// a real native button over the entire frame for clicks, keyboard and AX actions.
fn painted_button(id string, title string, frame ui2.Rect, box ui2.BoxStyle, color u32, enabled bool, align ui2.Align, inset f64) ui2.Element {
	focus_box := if enabled && workbench_focused_id() == id { ui2.BoxStyle{...box, border_color: workbench_colors.focus, border_left: 2, border_right: 2, border_top: 2, border_bottom: 2} } else { box }
	caption := ui2.label('${id}_caption', title, ui2.rect(inset, 0, frame.width - inset * 2, frame.height), ui2.TextStyle{
		size:  13
		color: color
		align: align
	})
	hit := ui2.button(id, '', ui2.rect(0, 0, frame.width, frame.height), ui2.BoxStyle{
		transparent: true
	}, ui2.TextStyle{ size: 13 })
	return ui2.view('${id}_container', frame, focus_box, [caption, ui2.Element{
		...hit
		enabled:             enabled
		accessibility_label: title
	}])
}

fn button(id string, title string, x f64, y f64, width f64, primary bool, enabled bool) ui2.Element {
	bg := if !enabled {
		workbench_colors.disabled_background
	} else if primary {
		workbench_colors.primary_background
	} else {
		workbench_colors.paper
	}
	color := if !enabled {
		workbench_colors.disabled_foreground
	} else if primary {
		workbench_colors.primary_foreground
	} else {
		workbench_colors.ink
	}
	return painted_button(id, title, ui2.rect(x, y, width, 34), ui2.BoxStyle{
		bg:            bg
		radius:        6
		border_color:  if primary && enabled { bg } else { workbench_colors.line }
		border_left:   1
		border_right:  1
		border_top:    1
		border_bottom: 1
	}, color, enabled, .center, 6)
}

fn sidebar_button(id string, title string, frame ui2.Rect, primary bool, selected bool, enabled bool, align ui2.Align) ui2.Element {
	bg := if selected || (primary && !enabled) {
		workbench_colors.soft_accent
	} else if primary {
		workbench_colors.primary_background
	} else {
		workbench_colors.sidebar
	}
	color := if !enabled {
		workbench_colors.disabled_foreground
	} else if primary {
		workbench_colors.primary_foreground
	} else {
		workbench_colors.ink
	}
	return painted_button(id, title, frame, ui2.BoxStyle{ bg: bg, radius: 6 }, color, enabled, align, 12)
}

fn sidebar_section_heading(id string, title string, y f64) ui2.Element {
	return ui2.view(id + '_section', ui2.rect(16, y, 180, 30), ui2.BoxStyle{transparent: true}, [
		ui2.view(id + '_accent', ui2.rect(0, 5, 3, 14), ui2.BoxStyle{bg: workbench_colors.accent, radius: 1}, []),
		ui2.label(id, title, ui2.rect(10, 0, 170, 24), ui2.TextStyle{size: 14, color: workbench_colors.muted}),
	])
}

fn project_button(id string, title string, badge string, frame ui2.Rect, selected bool, enabled bool) ui2.Element {
	bg := if selected { workbench_colors.soft_accent } else { workbench_colors.sidebar }
	caption := ui2.label('${id}_name', title, ui2.rect(12, if badge == '' { 12.0 } else { 3.0 }, frame.width - 24, 25), ui2.TextStyle{ size: 13, color: workbench_colors.ink, align: .left })
	mut children := [caption]
	if badge != '' {
		children << label('${id}_state', badge, 12, 27, frame.width - 24, 10, if badge.contains('失败') || badge.contains('待') || badge.contains('未就绪') { workbench_colors.warning } else if badge.ends_with('运行中') || badge.ends_with('SSH 已连接') { workbench_colors.green } else { workbench_colors.muted })
	}
	hit := ui2.button(id, '', ui2.rect(0, 0, frame.width, frame.height), ui2.BoxStyle{ transparent: true }, ui2.TextStyle{ size: 13 })
	children << ui2.Element{
		...hit
		enabled:             enabled
		accessibility_label: title + if badge != '' {
			' · ' + badge
		} else {
			''
		}
	}
	focused := enabled && workbench_focused_id() == id
	return ui2.view('${id}_container', frame, ui2.BoxStyle{ bg: bg, radius: 6,
		border_color: if focused { workbench_colors.accent } else { bg },
		border_left: if focused { 2.0 } else { 0.0 }, border_right: if focused { 2.0 } else { 0.0 },
		border_top: if focused { 2.0 } else { 0.0 }, border_bottom: if focused { 2.0 } else { 0.0 } }, children)
}

fn build_window() ui2.Element {
	refresh_system_appearance()
	root := workbench_text_layout(localize_element(workbench_font_layout(build_window_tree())))
	mut app := unsafe { workshop }
	$if linux {
		app.restore_pending_form_focus(root)
	}
	app.refresh_workbench_menus(root)
	$if linux {
		return linux_pixel_layout(root)
	}
	$if windows {
		return windows_pixel_layout(root, windows_display_scale())
	}
	return root
}

fn build_window_tree() ui2.Element {
	root := build_window_content()
	app := unsafe { workshop }
	$if windows {
		return root
	}
	if !app.environment_menu.open { return root }
	menu := ui2.dropdown_menu(ui2.DropdownMenuConfig{
		id:     'environment_menu'
		state:  app.environment_menu
		items:  app.environment_menu_items()
		anchor: ui2.rect(16, 82, 180, 34)
		window: workbench_bounds()
		width:  260
		label:  '选择运行环境'
		theme:  workbench_component_theme
	}) or { return root }
	mut children := root.children.clone()
	children << menu
	return ui2.Element{...root, children: children}
}

fn build_window_content() ui2.Element {
	mut app := unsafe { workshop }
	if app.worker_started && !app.quitting { poll_worker() }
	b := workbench_bounds()
	w := if b.width > 760 { b.width } else { 760.0 }
	h := if b.height > 660 { b.height } else { 660.0 }
	if app.desktop_update_open {
		settings := ui2.settings(app.update_settings_config()) or {
			label('desktop_update_error', '无法打开软件更新。', 24, 70, w - 48, 14, workbench_colors.ink)
		}
		return ui2.screen(workbench_colors.paper, [
			button('desktop_update_back', '返回工作台', 16, 12, 132, false, true),
			settings,
		])
	}
	content_x := 242.0
	// Content keeps its inset; page scroll viewports extend to the window edge.
	cw := w - content_x - 30
	mut side := [
		sidebar_brand(app.brand_mark),
		app.environment_selector(),
		sidebar_section_heading('project_label', '运行环境', 192),
	]
	mut project_rows := []ui2.Element{}
	mut y := 0.0
	if app.environment_id == '' {
	for i, project in app.projects {
		status := app.config_statuses[project.config_path] or { host.ConfigStatus{} }
		badge := match status.state {
			.pending { '配置待生效' }
			.unavailable {
				if status.pending { '待生效 · 检查失败' } else { '生效检查失败' }
			}
			else { '' }
		}
			project_rows << project_button('project_${i}', project.name, environment_runtime_badge(app.local_environment_version(), if badge != '' {
				badge
			} else if app.snapshot.project == project.config_path && app.snapshot.phase == .running {
				'运行中'
			} else {
				'配置入口'
			}), ui2.rect(0, y, 190, 52), i == app.selected, !app.new_project && !app.creating && app.snapshot.sequence >= app.sequence)
		y += 59
	}
	} else {
		for p in app.environment_profiles() {
			badge := if p.id == app.remote_snapshot.profile_id && app.remote_snapshot.connected {
				if app.remote_snapshot.restarting {
					'正在重启'
				} else if app.remote_snapshot.instance.startup_failed() {
					'重启失败 · 待修复'
				} else if !app.remote_snapshot.instance.ready {
					'业务未就绪'
				} else if app.remote_snapshot.config_status.pending {
					'配置待生效'
				} else {
					'SSH 已连接'
				}
			} else {
				'未连接'
			}
			project_rows << project_button('remote_select_${p.id}', p.name, environment_runtime_badge(app.remote_environment_version(p), badge), ui2.rect(0, y, 190, 52), p.id == app.remote_id && !app.show_servers, !app.remote_snapshot.busy && !app.server_busy)
			y += 59
		}
	}
	if project_rows.len == 0 {
		project_rows << label('project_list_empty', if app.environment_id == '' {
			'暂无运行环境'
		} else if app.remote_profiles_error != '' {
			'项目列表读取失败，请刷新重试'
		} else {
			'此位置暂无运行环境'
		}, 10, 8, 170, 11, workbench_colors.muted)
	}
	side << ui2.scroll('project_list', ui2.rect(12, 225, 190, h - 396), workbench_colors.sidebar, project_rows)
	can_choose := app.can_new_or_import()
	side << sidebar_button('new', '+ 新建', ui2.rect(16, 143, 85, 34), true, false, can_choose, .center)
	side << sidebar_button('import', '导入…', ui2.rect(111, 143, 85, 34), false, false, can_choose, .center)
	side << sidebar_button('server_home', '连接与服务器', ui2.rect(16, h - 125, 180, 34), false, app.show_remote, !app.creating, .left)
	side << sidebar_section_heading('env_label', '管理', h - 163)
	side << sidebar_button('runtime', '运行包', ui2.rect(16, h - 83, 180, 34), false, app.show_runtime, !app.creating, .left)
	side << label('binary_label', app.environment_version_label(), 22, h - 32, 170, 11, workbench_colors.muted)
	mut children := [ui2.view('workbench_sidebar', ui2.rect(0, 0, 214, h), ui2.BoxStyle{
		bg:           workbench_colors.sidebar
		border_color: workbench_colors.line
		border_right: 1
	}, side)]
	if app.show_development {
		app.sync_development_apps()
		children << ui2.scroll('development_mcp_page', ui2.rect(content_x, 0, cw + 30, h), workbench_colors.paper, development_mcp_view(app, cw))
		return ui2.screen(workbench_colors.paper, children)
	}
	if app.show_shared_relays {
		children << ui2.scroll('shared_relays_page', ui2.rect(content_x, 0, cw + 30, h), workbench_colors.paper, shared_relays_view(app, cw))
		return ui2.screen(workbench_colors.paper, children)
	}
	if app.show_component_install {
		children << ui2.scroll('component_page', ui2.rect(content_x, 0, cw + 30, h), workbench_colors.paper, component_installation_view(app, cw))
		return ui2.screen(workbench_colors.paper, children)
	}
	if app.show_deployment {
		children << ui2.scroll('deployment_page', ui2.rect(content_x, 0, cw + 30, h), workbench_colors.paper, application_deployment_view(app, cw))
		return ui2.screen(workbench_colors.paper, children)
	}
	if app.show_remote && !app.show_servers && !app.remote_edit_connection && app.remote_snapshot.connected && app.remote_snapshot.profile_id==app.remote_id && same_remote_connection(app.remote_form(),app.remote_connected_form) && !app.show_runtime {
		children << ui2.scroll('runtime_workspace_page',ui2.rect(content_x,0,cw+30,h),workbench_colors.paper,runtime_workspace_view(mut app,cw,h))
		return ui2.screen(workbench_colors.paper,children)
	}
	if app.show_remote {
		children << ui2.scroll('remote_instances_page', ui2.rect(content_x, 0, cw + 30, h), workbench_colors.paper, if app.show_servers {
			remote_servers_view(app, cw)
		} else {
			remote_instances_view(app, cw)
		})
		return ui2.screen(workbench_colors.paper, children)
	}
	if app.show_runtime {
		children << ui2.scroll('runtime_page', ui2.rect(content_x, 0, cw + 30, h), workbench_colors.paper, runtime_settings_view(app, cw))
		return ui2.screen(workbench_colors.paper, children)
	}
	if app.show_takeover && app.environment_id == '' {
		children << ui2.scroll('takeover_page', ui2.rect(content_x, 0, cw + 30, h), workbench_colors.paper, if app.show_relay_monitor {
			relay_monitor_view(app, cw)
		} else {
			takeover_view(app, cw)
		})
		return ui2.screen(workbench_colors.paper,children)
	}
	if app.environment_id != '' {
		children << ui2.scroll('environment_projects_page', ui2.rect(content_x, 0, cw + 30, h), workbench_colors.paper, remote_instances_view(app, cw))
		return ui2.screen(workbench_colors.paper, children)
	}
	if app.show_rollback && !app.new_project && app.projects.len > 0 {
		children << ui2.scroll('config_rollback_page', ui2.rect(content_x, 0, cw + 30, h), workbench_colors.paper, config_rollback_view(app, cw))
		return ui2.screen(workbench_colors.paper, children)
	}
	if app.show_history && !app.new_project && app.projects.len > 0 {
		children << ui2.scroll('version_history_page', ui2.rect(content_x, 0, cw + 30, h), workbench_colors.paper, version_history_view(app, cw))
		return ui2.screen(workbench_colors.paper, children)
	}
	if app.show_config_diff && !app.new_project && app.projects.len > 0 {
		children << ui2.scroll('config_diff_page', ui2.rect(content_x, 0, cw + 30, h), workbench_colors.paper, config_diff_view(app, cw))
		return ui2.screen(workbench_colors.paper, children)
	}
	if app.show_details && !app.new_project && app.projects.len > 0 {
		children << ui2.scroll('project_details', ui2.rect(content_x, 0, cw + 30, h), workbench_colors.paper, project_details_view(app, cw))
		return ui2.screen(workbench_colors.paper, children)
	}
	if app.new_project {
		children << ui2.scroll('new_project_form', ui2.rect(content_x, 0, cw + 30, h), workbench_colors.paper, new_project_view(app, 0, cw))
		return ui2.screen(workbench_colors.paper, children)
	}
	if app.projects.len == 0 {
		children << label('empty_breadcrumb', '本地项目  /  开始使用', content_x, 25, cw, 12, workbench_colors.muted)
		children << label('empty', '还没有 vhttpd 运行环境', content_x, 73, cw, 26, workbench_colors.ink)
		children << state_notice('empty_guide', '从一个 vjsx 模板开始', '创建 vhttpd 运行配置及一个起始应用；同一运行环境可以继续承载其他应用。', ui2.rect(content_x, 132, cw, 106), 'info')
		children << button('empty_new', '新建运行环境', content_x, 262, 160, true, true)
		children << button('empty_import', '导入运行配置', content_x + 176, 262, 140, false, true)
		if app.notice != '' {
			children << state_notice('empty_notice', '项目列表暂不可用', app.notice, ui2.rect(content_x, 322, cw, 112), 'warning')
		}
		return ui2.screen(workbench_colors.paper, children)
	}
	children << ui2.scroll('runtime_workspace_page',ui2.rect(content_x,0,cw+30,h),workbench_colors.paper,runtime_workspace_view(mut app,cw,h))
	return ui2.screen(workbench_colors.paper,children)
}

fn workbench_bounds() ui2.Rect {
 b := ui2.bounds()
	$if windows {
		scale := windows_display_scale()
		return ui2.rect(0, 0, b.width / scale, b.height / scale)
	}
 return b
}

fn (mut app Workshop) close_auxiliary_project_views() {
	app.show_takeover = false
	app.show_relay_monitor = false
}
