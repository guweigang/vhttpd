module main

import host
import math
import os
import strconv
import time
import ui2

const sidebar_default_width = 214.0
const sidebar_min_width = 200.0
const sidebar_max_width = 340.0
// Preserve the existing 488-point content width at the 760-point window minimum.
const sidebar_content_min_width = 488.0
const sidebar_content_insets = 58.0
const sidebar_resize_id = 'sidebar_resize'

struct SidebarResize {
mut:
	width f64 = sidebar_default_width
	phase ui2.ResizeHandlePhase
	dragging bool
	press_x f64
	press_width f64
	last_click ui2.TitleBarClick
}

fn sidebar_visible_width(preferred f64, window_width f64) f64 {
	limit := math.max(sidebar_min_width, math.min(sidebar_max_width, window_width - sidebar_content_min_width - sidebar_content_insets))
	return math.max(sidebar_min_width, math.min(preferred, limit))
}

fn sidebar_width_path() string {
	return os.join_path(host.workbench_data_dir(), 'sidebar-width')
}

fn load_sidebar_width(path string) f64 {
	text := os.read_file(path) or { return sidebar_default_width }
	width := strconv.atof64(text.trim_space()) or { return sidebar_default_width }
	if !(width >= sidebar_min_width && width <= sidebar_max_width) { return sidebar_default_width }
	return width
}

fn save_sidebar_width(path string, width f64) ! {
	os.mkdir_all(os.dir(path))!
	temporary := path + '.tmp-' + os.getpid().str()
	defer { os.rm(temporary) or {} }
	os.write_file(temporary, math.round(width).str() + '\n')!
	os.mv(temporary, path)!
}

// Return true only when a finished gesture needs persistence. Shrinking the
// window never changes the saved preference; enlarging it restores that width.
fn (mut state SidebarResize) pointer(event ui2.PointerEvent, window_width f64, now i64) bool {
	match event.phase {
		'enter' { if !state.dragging { state.phase = .hovered } }
		'leave' { if !state.dragging { state.phase = .idle } }
		'down' {
			press := ui2.TitleBarClick{time_ms: now, x: event.x, y: event.y, count: 1}
			if ui2.title_bar_is_double_click(state.last_click, press) {
				state.width = sidebar_default_width
				state.last_click = ui2.TitleBarClick{}
				state.dragging = false
				state.phase = .hovered
				return true
			}
			state.last_click = press
			state.press_x = event.x
			state.press_width = sidebar_visible_width(state.width, window_width)
			state.dragging = true
			state.phase = .pressed
		}
		'drag', 'up' {
			if !state.dragging { return false }
			moved := math.abs(event.x - state.press_x) > 3 || state.phase == .dragging
			if moved {
				state.width = sidebar_visible_width(state.press_width + event.x - state.press_x, window_width)
				state.phase = .dragging
				state.last_click = ui2.TitleBarClick{}
			}
			if event.phase == 'up' {
				state.dragging = false
				state.phase = .idle
				return moved
			}
		}
		else {}
	}
	return false
}

fn (app &Workshop) sidebar_width() f64 {
	return sidebar_visible_width(app.sidebar_resize.width, math.max(workbench_bounds().width, 760))
}

fn (app &Workshop) sidebar_handle(width f64, height f64) ui2.Element {
	handle := ui2.resize_handle(ui2.ResizeHandleConfig{
		id: sidebar_resize_id
		frame: ui2.resize_handle_frame(.horizontal, width - 1, 0, height, .straddle)
		phase: app.sidebar_resize.phase
		focus_visible: workbench_focused_id() == sidebar_resize_id
		accessibility_label: ui_text('调整侧栏宽度')
		accessibility_value: int(width).str()
		theme: workbench_component_theme
	}) or { return ui2.view(sidebar_resize_id, ui2.rect(width - 1,0,1,height), ui2.BoxStyle{bg:workbench_colors.line}, []) }
	return ui2.Element{...handle, tooltip: ui_text('拖动调整侧栏宽度；双击恢复默认')}
}

fn (mut app Workshop) persist_sidebar_width() {
	save_sidebar_width(sidebar_width_path(), app.sidebar_resize.width) or { app.notice = '无法保存侧栏宽度：' + err.msg() }
}

fn (mut app Workshop) handle_sidebar_resize(event string) bool {
	pointer := ui2.parse_pointer_event(event) or { return false }
	if pointer.action != sidebar_resize_id { return false }
	mut logical_pointer := pointer
	$if windows {
		scale := windows_display_scale()
		logical_pointer = ui2.PointerEvent{...pointer, x: pointer.x / scale, y: pointer.y / scale}
	}
	if app.sidebar_resize.pointer(logical_pointer, math.max(workbench_bounds().width, 760), time.ticks()) {
		app.persist_sidebar_width()
	}
	ui2.refresh()
	return true
}

fn (mut app Workshop) sidebar_resize_key(event ui2.KeyEvent) bool {
	if workbench_focused_id() != sidebar_resize_id || event.cmd || event.ctrl || event.alt { return false }
	width := app.sidebar_width()
	step := if event.shift { 30.0 } else { 10.0 }
	next := match event.code {
		.left { width - step }
		.right { width + step }
		.home { sidebar_min_width }
		.end { sidebar_max_width }
		.enter { sidebar_default_width }
		else { return false }
	}
	app.sidebar_resize.width = sidebar_visible_width(next, math.max(workbench_bounds().width, 760))
	app.persist_sidebar_width()
	ui2.refresh()
	return true
}
