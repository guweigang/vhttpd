@[has_globals]
module main

import host
import os
import time
import ui2

#include <stdlib.h>

fn C.atexit(fn ()) int

const workbench_paper = u32(0xffffff)
const workbench_sidebar = u32(0xf4f7fb)
const workbench_ink = u32(0x17202a)
const workbench_muted = u32(0x627184)
const workbench_line = u32(0xe0e7f0)
const workbench_green = u32(0x2c6149)
const workbench_accent = u32(0x2563eb)
const workbench_soft_accent = u32(0xeaf1ff)

@[heap]
struct Workshop {
mut:
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
	show_shared_relays   bool
	shared_relays        []host.SharedRelay
	shared_id            string
	shared_name          string
	shared_url           string
	shared_token         string
	shared_remote_id     string
	shared_message       string
	shared_testing       bool
	shared_use_pending   bool
	shared_results       chan host.RelayProbeResult = chan host.RelayProbeResult{cap: 1}
}

const workshop = &Workshop{}

fn main() {
	$if !macos {
		eprintln('此 ui2 宿主原型当前只验证并交付 macOS。')
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
	if '--smoke' in os.args {
		run_smoke(root) or {
			eprintln(err)
			exit(1)
		}
		return
	}
	mut app := unsafe { workshop }
	app.binary = host.selected_runtime(os.executable(), root) or {
		app.notice = err.msg()
		host.workbench_binary(os.executable(), root)
	}
	app.inspect_binary(app.binary, false)
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
	app.worker = host.new_worker()
	app.worker_started = true
	if app.projects.len > 0 { app.select_current() }
	C.atexit(cleanup)
	ui2.set_menu_bar([ui2.Menu{
		title: '项目'
		items: [ui2.menu_item('new', '新建项目…'), ui2.menu_item('import', '导入配置…'),
			ui2.menu_item('folder', '打开项目目录'), ui2.menu_separator(),
			ui2.menu_item('quit', '退出工作台')]
	}])
	ui2.after(0.5, poll_worker)
	ui2.run_window('vhttpd · 本地工作台', 980, 740, build_window, handle_event)
	cleanup()
}

fn default_projects(root string) []host.Project {
	return [host.Project{
		name:        'hello-vjsx'
		config_path: os.join_path(root, 'desktop', 'examples', 'hello-vjsx', 'vhttpd.toml')
		workdir:     root
	}, host.Project{
		name:        'api-playground'
		config_path: os.join_path(root, 'desktop', 'examples', 'api-playground', 'vhttpd.toml')
		workdir:     root
	}]
}

fn cleanup() {
	mut app := unsafe { workshop }
	if !app.worker_started || app.quitting { return }
	app.quitting = true
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
	app.poll_runtime()
	app.poll_creation()
	select {
		result := <-app.shared_results {
			app.shared_testing = false
			app.shared_message = time.now().format_ss() + ' · ' + result.stage + ' · ' + result.message + ' (${result.elapsed_ms} ms)'
		}
		else {
		}
	}
	select {
		s := <-app.worker.snapshots {
			if s.sequence < app.sequence {
				ui2.after(0.5, poll_worker)
				return
			}
			if s.project != '' {
				app.config_statuses[s.project] = s.config_status
			}
			if s.log_focus_serial > app.snapshot.log_focus_serial {
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
	ui2.after(0.5, poll_worker)
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
	mut app := unsafe { workshop }
	if app.creating { return }
	if app.handle_runtime_event(event) {
		ui2.refresh()
		return
	}
	if app.handle_shared_relay_event(event) {
		app.show_runtime = false
		return
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
			dirs := ui2.open_folder_dialog(
				title:     '选择项目存放目录'
				directory: app.new_parent
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
			if ui2.confirm('强制停止', '仅强制结束此工作台启动的实例及其进程组。未完成的工作可能中断。') {
				app.restart_after = false
				app.send(.force_stop)
			}
		}
		'restart', 'apply_restart' {
			if app.snapshot.phase != .running { return }
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
		'all_logs' { app.send(.show_all_logs) }
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
				title:     '选择 vhttpd 可执行文件'
				directory: os.dir(app.binary)
			)
			if files.len > 0 && app.snapshot.pid == 0 && !app.runtime_busy {
				app.inspect_binary(os.real_path(files[0]), true)
			}
		}
		'quit' {
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
		title:   '选择 vhttpd TOML 配置'
		filters: [ui2.FileDialogFilter{
			name:       'vhttpd 配置'
			extensions: ['toml']
		}]
	)
	if files.len == 0 { return }
	// Existing v2 projects may resolve relative entries from a chosen working
	// directory. Do not silently assume the config's directory is that root.
	dirs := ui2.open_folder_dialog(title: '选择项目工作目录', directory: os.dir(files[0]))
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

fn label(id string, text string, x f64, y f64, width f64, size f64, color u32) ui2.Element {
	return ui2.label(id, text, ui2.rect(x, y, width, 25), ui2.TextStyle{ size: size, color: color })
}

// Keep text independent of NSButton's disabled-title drawing, while retaining
// a real native button over the entire frame for clicks, keyboard and AX actions.
fn painted_button(id string, title string, frame ui2.Rect, box ui2.BoxStyle, color u32, enabled bool, align ui2.Align, inset f64) ui2.Element {
	caption := ui2.label('${id}_caption', title, ui2.rect(inset, 0, frame.width - inset * 2, frame.height), ui2.TextStyle{
		size:  13
		color: color
		align: align
	})
	hit := ui2.button(id, '', ui2.rect(0, 0, frame.width, frame.height), ui2.BoxStyle{
		transparent: true
	}, ui2.TextStyle{ size: 13 })
	return ui2.view('${id}_container', frame, box, [caption, ui2.Element{
		...hit
		enabled:             enabled
		accessibility_label: title
	}])
}

fn button(id string, title string, x f64, y f64, width f64, primary bool, enabled bool) ui2.Element {
	bg := if !enabled {
		u32(0xe9edf2)
	} else if primary {
		workbench_accent
	} else {
		workbench_paper
	}
	color := if !enabled {
		u32(0x596575)
	} else if primary {
		workbench_paper
	} else {
		workbench_ink
	}
	return painted_button(id, title, ui2.rect(x, y, width, 34), ui2.BoxStyle{
		bg:            bg
		radius:        6
		border_color:  workbench_line
		border_left:   1
		border_right:  1
		border_top:    1
		border_bottom: 1
	}, color, enabled, .center, 6)
}

fn sidebar_button(id string, title string, frame ui2.Rect, primary bool, selected bool, enabled bool, align ui2.Align) ui2.Element {
	bg := if selected || (primary && !enabled) {
		workbench_soft_accent
	} else if primary {
		workbench_accent
	} else {
		workbench_sidebar
	}
	color := if !enabled {
		u32(0x596575)
	} else if primary {
		workbench_paper
	} else {
		workbench_ink
	}
	return painted_button(id, title, frame, ui2.BoxStyle{ bg: bg, radius: 6 }, color, enabled, align, 12)
}

fn project_button(id string, title string, badge string, frame ui2.Rect, selected bool, enabled bool) ui2.Element {
	bg := if selected { workbench_soft_accent } else { workbench_sidebar }
	caption := ui2.label('${id}_name', title, ui2.rect(12, if badge == '' { 12.0 } else { 3.0 }, frame.width - 24, 25), ui2.TextStyle{ size: 13, color: workbench_ink, align: .left })
	mut children := [caption]
	if badge != '' {
		children << label('${id}_state', badge, 12, 27, frame.width - 24, 10, workbench_warning)
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
	return ui2.view('${id}_container', frame, ui2.BoxStyle{ bg: bg, radius: 6 }, children)
}

fn build_window() ui2.Element {
	app := unsafe { workshop }
	b := ui2.bounds()
	w := if b.width > 760 { b.width } else { 760.0 }
	h := if b.height > 660 { b.height } else { 660.0 }
	content_x := 242.0
	cw := w - content_x - 30
	mut side := [
		ui2.Element{ ...ui2.image('brand_mark', app.brand_mark, ui2.rect(22, 18, 38, 38)), accessibility_label: 'vhttpd 品牌标志' },
		ui2.label('brand', 'vhttpd', ui2.rect(70, 16, 120, 30), ui2.TextStyle{ size: 23, color: workbench_ink, bold: true }),
		label('local_label', '本地工作台', 70, 45, 120, 11, workbench_muted),
		label('project_label', '项目', 22, 96, 160, 12, workbench_muted),
	]
	mut project_rows := []ui2.Element{}
	mut y := 0.0
	for i, project in app.projects {
		status := app.config_statuses[project.config_path] or { host.ConfigStatus{} }
		badge := match status.state {
			.pending { '配置待生效' }
			.unavailable {
				if status.pending { '待生效 · 检查失败' } else { '生效检查失败' }
			}
			else { '' }
		}
		project_rows << project_button('project_${i}', project.name, badge, ui2.rect(0, y, 190, 52), i == app.selected, !app.new_project && !app.creating)
		y += 59
	}
	side << ui2.scroll('project_list', ui2.rect(12, 130, 190, h - 445), workbench_sidebar, project_rows)
	can_choose := !app.new_project && !app.runtime_busy && app.snapshot.pid == 0 && app.snapshot.phase !in [
		.starting,
		.stopping,
	]
	side << sidebar_button('new', '+  新建项目', ui2.rect(16, h - 300, 180, 34), true, false, can_choose, .center)
	side << sidebar_button('import', '导入已有项目', ui2.rect(16, h - 257, 180, 34), false, false, can_choose, .center)
	side << sidebar_button('shared_relays', '远端 Relay', ui2.rect(16, h - 214, 180, 34), false, app.show_shared_relays, !app.creating, .center)
	side << label('env_label', '运行环境 · ' + app.runtime_info.source, 22, h - 161, 170, 12, workbench_muted)
	side << label('binary_label', if app.runtime_info.ready {
		'vhttpd ' + app.runtime_info.version
	} else if app.runtime_busy {
		'正在检查运行包…'
	} else {
		'运行包不可用'
	}, 22, h - 134, 170, 13, workbench_ink)
	side << sidebar_button('runtime', if app.runtime_checked && !app.runtime_info.ready {
		'安装 / 选择运行包'
	} else {
		'管理运行环境'
	}, ui2.rect(16, h - 94, 180, 34), false, app.show_runtime, !app.creating, .center)
	mut children := [ui2.view('workbench_sidebar', ui2.rect(0, 0, 214, h), ui2.BoxStyle{
		bg:           workbench_sidebar
		border_color: workbench_line
		border_right: 1
	}, side)]
	if app.show_runtime {
		children << ui2.scroll('runtime_page', ui2.rect(content_x, 0, cw, h), workbench_paper, runtime_settings_view(app, cw))
		return ui2.screen(workbench_paper, children)
	}
	if app.show_shared_relays {
		children << ui2.scroll('shared_relays_page', ui2.rect(content_x, 0, cw, h), workbench_paper, shared_relays_view(app, cw))
		return ui2.screen(workbench_paper, children)
	}
	if app.show_rollback && !app.new_project && app.projects.len > 0 {
		children << ui2.scroll('config_rollback_page', ui2.rect(content_x, 0, cw, h), workbench_paper, config_rollback_view(app, cw))
		return ui2.screen(workbench_paper, children)
	}
	if app.show_history && !app.new_project && app.projects.len > 0 {
		children << ui2.scroll('version_history_page', ui2.rect(content_x, 0, cw, h), workbench_paper, version_history_view(app, cw))
		return ui2.screen(workbench_paper, children)
	}
	if app.show_config_diff && !app.new_project && app.projects.len > 0 {
		children << ui2.scroll('config_diff_page', ui2.rect(content_x, 0, cw, h), workbench_paper, config_diff_view(app, cw))
		return ui2.screen(workbench_paper, children)
	}
	if app.show_details && !app.new_project && app.projects.len > 0 {
		children << ui2.scroll('project_details', ui2.rect(content_x, 0, cw, h), workbench_paper, project_details_view(app, cw))
		return ui2.screen(workbench_paper, children)
	}
	if app.new_project {
		children << ui2.scroll('new_project_form', ui2.rect(content_x, 0, cw, h), workbench_paper, new_project_view(app, 0, cw))
		return ui2.screen(workbench_paper, children)
	}
	if app.projects.len == 0 {
		children << label('empty_breadcrumb', '本地项目  /  开始使用', content_x, 25, cw, 12, workbench_muted)
		children << label('empty', '还没有项目', content_x, 73, cw, 26, workbench_ink)
		children << state_notice('empty_guide', '从一个 vjsx 模板开始', '选择模板和存放目录，即可创建项目；创建后可自动启动并登录 Admin UI。', ui2.rect(content_x, 132, cw, 106), 'info')
		children << button('empty_new', '新建 vjsx 项目', content_x, 262, 160, true, true)
		children << button('empty_import', '导入已有项目', content_x + 176, 262, 140, false, true)
		if app.notice != '' {
			children << state_notice('empty_notice', '项目列表暂不可用', app.notice, ui2.rect(content_x, 322, cw, 112), 'warning')
		}
		return ui2.screen(workbench_paper, children)
	}
	project := app.projects[app.selected]
	s := app.snapshot
	phase := match s.phase {
		.stopped { '已停止' }
		.starting { '启动中…' }
		.running { '● 运行中' }
		.stopping { '停止中…' }
		.failed { '运行失败' }
	}
	busy := s.phase in [.starting, .stopping]
	children << label('breadcrumb', '本地项目  /  ${project.name}', content_x, 25, cw, 12, workbench_muted)
	children << label('title', project.name, content_x, 73, cw - 170, 26, workbench_ink)
	phase_tone := if s.phase == .failed {
		'danger'
	} else if s.phase == .running {
		'good'
	} else {
		'info'
	}
	phase_bg, phase_ink := state_colors(phase_tone)
	children << ui2.view('phase_badge', ui2.rect(w - 160, 73, 130, 30), ui2.BoxStyle{
		bg:     if s.phase == .stopped {
			workbench_sidebar
		} else {
			phase_bg
		}
		radius: 6
	}, [
		ui2.label('status', phase, ui2.rect(4, 0, 122, 30), ui2.TextStyle{
			size:  12
			color: if s.phase == .stopped {
				workbench_muted
			} else {
				phase_ink
			}
			align: .center
		}),
	])
	children << label('path', os.dir(project.config_path), content_x, 108, cw, 12, workbench_muted)
	if s.pid == 0 && !busy {
		children << button('start', if s.phase == .failed { '重新启动' } else { '启动项目' }, content_x, 155, 103, true, true)
	} else {
		children << button(if s.can_force { 'force' } else { 'stop' }, if s.can_force {
			'强制停止'
		} else {
			'停止'
		}, content_x, 155, 103, false, s.phase != .stopping || s.can_force)
	}
	children << button('restart', '重启', content_x + 115, 155, 77, false, s.phase == .running)
	children << button('folder', '打开项目目录', content_x + 204, 155, 123, false, true)
	children << button('details', '配置 / Relay', content_x + 339, 155, 110, false, true)
	children << button('edit_source', '打开源码', content_x + 461, 155, 90, false, s.entry != '')
	children << label('admin_section', '管理界面', content_x, 215, cw, 13, workbench_ink)
	children << ui2.view('admin_card', ui2.rect(content_x, 250, cw, 105), ui2.BoxStyle{
		bg:            workbench_paper
		radius:        8
		border_color:  workbench_line
		border_left:   1
		border_right:  1
		border_top:    1
		border_bottom: 1
	}, [label('admin_title', 'Admin UI', 18, 10, cw - 190, 16, workbench_ink),
		label('admin_subtitle', '运行总览、请求链路与配置发布', 18, 36, cw - 190, 12, workbench_muted),
		label('admin_address', if s.admin_url != '' {
			s.admin_url
		} else {
			'启动就绪后打开默认浏览器'
		}, 18, 65, cw - 190, 11, workbench_muted),
		button('admin', '打开浏览器 ↗', cw - 153, 12, 134, true, s.phase == .running),
		button('open_app', '访问业务服务 ↗', cw - 153, 55, 134, false, s.phase == .running && s.app_url != '')])
	children << config_status_view(app, content_x, 367, cw)
	children << label('config_label', '配置文件', content_x, 460, cw / 2, 11, workbench_muted)
	children << label('config_value', os.file_name(project.config_path), content_x, 481, cw / 2 - 10, 12, workbench_ink)
	children << label('pid_label', '进程 / 执行器', content_x + cw / 2, 460, cw / 2, 11, workbench_muted)
	children << label('pid_value', if s.pid > 0 {
		'PID ${s.pid}  ·  ${s.executor}'
	} else {
		'未启动'
	}, content_x + cw / 2, 481, cw / 2, 12, workbench_ink)
	children << label('logs_label', if s.log_filter == '' {
		'运行日志'
	} else {
		'请求日志 · ${s.log_filter}'
	}, content_x, 520, cw - 190, 12, workbench_ink)
	if s.log_filter != '' {
		children << button('all_logs', '显示全部日志', w - 220, 517, 115, false, true)
	}
	children << button('clear', '清空', w - 95, 517, 65, false, true)
	mut logs := ui2.text_area('logs', if s.logs == '' {
		if s.phase == .failed {
			'尚无运行日志。请核对项目配置和运行程序后重试。'
		} else if s.phase == .running {
			'暂无运行日志。'
		} else {
			'启动项目后，运行日志会显示在这里。'
		}
	} else {
		s.logs
	}, ui2.rect(content_x, 560, cw, h - 645), ui2.BoxStyle{ bg: workbench_sidebar, radius: 7 }, ui2.TextStyle{ size: 11, color: workbench_ink, font_family: 'Menlo' })
	children << ui2.Element{ ...logs, readonly: true }
	message := if app.notice != '' {
		app.notice
	} else if s.message != '' {
		s.message
	} else {
		'关闭浏览器不影响运行；退出工作台时停止实例。'
	}
	children << ui2.label('message', message, ui2.rect(content_x, h - 73, cw, 56), ui2.TextStyle{
		size:  12
		color: if s.phase == .failed {
			workbench_danger
		} else {
			workbench_muted
		}
		lines: 2
	})
	return ui2.screen(workbench_paper, children)
}
