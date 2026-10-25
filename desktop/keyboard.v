module main

import ui2

struct FocusTarget {
	id string
	kind ui2.Kind
	scroll string
	frame ui2.Rect
}

// Follow the actual rendered tree, so hidden/disabled controls never trap Tab.
fn collect_focus_targets(element ui2.Element, scroll string, x f64, y f64, mut targets []FocusTarget) {
	if !element.enabled || element.id in ['workbench_sidebar', 'server_list', 'shared_list'] { return }
	if element.kind in [.text_field, .button, .checkbox] && !element.readonly && element.id != '' {
		targets << FocusTarget{id: element.id, kind: element.kind, scroll: scroll, frame: ui2.rect(x + element.frame.x, y + element.frame.y, element.frame.width, element.frame.height)}
	}
	if element.kind == .scroll {
		for child in element.children { collect_focus_targets(child, element.id, 0, 0, mut targets) }
	} else {
		for child in element.children { collect_focus_targets(child, scroll, x + element.frame.x, y + element.frame.y, mut targets) }
	}
}

fn focus_targets(root ui2.Element) []FocusTarget {
	mut targets := []FocusTarget{}
	collect_focus_targets(root, '', 0, 0, mut targets)
	return targets
}

fn next_focus_target(targets []FocusTarget, current string, reverse bool) ?FocusTarget {
	if targets.len == 0 { return none }
	mut index := -1
	for i, target in targets { if target.id == current { index = i; break } }
	if index < 0 { return targets[if reverse { targets.len - 1 } else { 0 }] }
	return targets[(index + if reverse { targets.len - 1 } else { 1 }) % targets.len]
}

fn workbench_key(key string) {
	mut app := unsafe { workshop }
	if key in ['tab', 'shift+tab'] {
		if ui2.focused_text_area_id() != '' { return }
		target := next_focus_target(focus_targets(build_window()), ui2.focused_id(), key == 'shift+tab') or { return }
		ui2.consume_key()
		if target.scroll != '' { ui2.scroll_to_rect(target.scroll, target.frame.x, target.frame.y - 12, target.frame.width, target.frame.height + 24) }
		ui2.focus(target.id)
		ui2.refresh()
		return
	}
	match key {
		'cmd+n' { handle_event('new') }
		'cmd+o' { handle_event('import') }
		'cmd+comma', 'cmd+,' { handle_event('runtime') }
		'cmd+enter', 'cmd+return' { submit_active_form() }
		'escape' {
			if app.show_remote && app.show_servers && app.server_snapshot.host_key.id != '' { handle_event('server_disconnect'); return }
			if app.show_remote && !app.show_servers && app.remote_snapshot.host_key.id != '' { handle_event('remote_disconnect'); return }
			if app.creating || app.server_busy || app.server_snapshot.busy || app.remote_snapshot.busy { return }
			if app.new_project { handle_event('new_cancel') }
			else if app.show_remote { handle_event('remote_close') }
			else if app.show_runtime { handle_event('runtime_close') }
			else if app.show_shared_relays { handle_event('shared_close') }
		}
		'cmd+w' { handle_event('quit') }
		else {}
	}
}

// NSTextField handles Escape itself unless it is consumed before the field
// editor. Tab keeps using ui2's text-command hook; editing keys remain native.
fn workbench_physical_key(event ui2.KeyEvent) {
	if event.code == .escape {
		workbench_key('escape')
		ui2.consume_key()
		return
	}
	if event.code in [.space, .enter] && !event.cmd && !event.ctrl && !event.alt {
		for target in focus_targets(build_window()) {
			if target.id != ui2.focused_id() || target.kind !in [.button, .checkbox] { continue }
			ui2.consume_key()
			handle_event(target.id)
			return
		}
	}
}

fn submit_active_form() {
	app := unsafe { workshop }
	ids := if app.new_project { ['new_submit'] }
		else if app.show_remote && app.show_servers { ['server_connect'] }
		else if app.show_remote { ['remote_connect'] }
		else if app.show_shared_relays { ['shared_save'] }
		else { []string{} }
	// Enter never accepts a host fingerprint, deletes a record, or deploys a runtime.
	for target in focus_targets(build_window()) {
		if target.id in ids { handle_event(target.id); return }
	}
}

fn choice_button(id string, title string, x f64, y f64, width f64, selected bool, enabled bool) ui2.Element {
	return painted_button(id, title, ui2.rect(x, y, width, 34), ui2.BoxStyle{
		bg: if selected { workbench_soft_accent } else { workbench_paper }
		radius: 6
		border_color: if selected { workbench_accent } else { workbench_line }
		border_left: 1
		border_right: 1
		border_top: 1
		border_bottom: 1
	}, if !enabled { u32(0x596575) } else if selected { workbench_accent } else { workbench_ink }, enabled, .center, 6)
}
