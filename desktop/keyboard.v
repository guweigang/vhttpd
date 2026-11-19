module main

import ui2
import os

struct FocusTarget {
	id string
	action string
	selected bool
	choices []string
	value string
	kind ui2.Kind
	scroll string
	frame ui2.Rect
}

// Follow the actual rendered tree, so hidden/disabled controls never trap Tab.
fn collect_focus_targets(element ui2.Element, scroll string, x f64, y f64, mut targets []FocusTarget) {
	if !element.enabled || element.hidden { return }
	start := targets.len
	if (element.kind in [.text_field, .text_area, .dropdown, .button, .checkbox] || (element.kind == .view && element.button_behavior)) && element.id != '' {
		targets << FocusTarget{id: element.id, action: if element.action_id != '' { element.action_id } else { element.id }, choices: if element.kind == .dropdown { element.menu.map(it.title) } else { []string{} }, value: element.text, kind: if element.button_behavior { ui2.Kind.button } else { element.kind }, scroll: scroll, frame: ui2.rect(x + element.frame.x, y + element.frame.y, element.frame.width, element.frame.height)}
	}
	// Source declarations can put footer actions before header actions. Walk
	// each container in visual order while retaining its column/list boundary.
	mut order := []int{}
	for i in 0 .. element.children.len { order << i }
	for i in 1 .. order.len {
		mut j := i
		for j > 0 {
			a := element.children[order[j]].frame
			b := element.children[order[j-1]].frame
			if a.y > b.y || (a.y == b.y && a.x >= b.x) { break }
			order[j], order[j-1] = order[j-1], order[j]
			j--
		}
	}
	for i in order {
		child := element.children[i]
		if element.kind == .scroll {
			collect_focus_targets(child, element.id, 0, 0, mut targets)
		} else {
			collect_focus_targets(child, scroll, x + element.frame.x, y + element.frame.y, mut targets)
		}
	}
	if element.kind == .view && element.box.bg == workbench_colors.soft_accent {
		for i in start .. targets.len {
			if focus_selection_group(targets[i].id) != '' { targets[i] = FocusTarget{...targets[i], selected: true} }
		}
	}
}

fn all_focus_targets(root ui2.Element) []FocusTarget {
	mut targets := []FocusTarget{}
	collect_focus_targets(root, '', 0, 0, mut targets)
	return targets
}

// One Tab stop per list/tab strip; arrows move within that selection group.
// This keeps a long project list from trapping users in dozens of Tab stops.
fn focus_targets(root ui2.Element) []FocusTarget {
	all := all_focus_targets(root)
	current := workbench_focused_id()
	mut chosen := map[string]string{}
	for target in all {
		group := focus_selection_group(target.id)
		if group == '' { continue }
		if group !in chosen || target.selected { chosen[group] = target.id }
	}
	for target in all {
		group := focus_selection_group(target.id)
		if group != '' && target.id == current { chosen[group] = target.id }
	}
	return all.filter(focus_selection_group(it.id) == '' || chosen[focus_selection_group(it.id)] == it.id)
}

fn next_focus_target(targets []FocusTarget, current string, reverse bool) ?FocusTarget {
	if targets.len == 0 { return none }
	mut index := -1
	for i, target in targets { if target.id == current { index = i; break } }
	if index < 0 { return targets[if reverse { targets.len - 1 } else { 0 }] }
	return targets[(index + if reverse { targets.len - 1 } else { 1 }) % targets.len]
}

fn workbench_key(raw_key string) {
	// AppKit text views send namespaced text commands rather than window keys.
	if raw_key.starts_with('text:') {
		command := raw_key.all_after_last(':')
		if command in ['tab', 'shift+tab'] {
			workbench_key(command)
			ui2.consume_text_key()
		}
		return
	}
	$if macos { if raw_key == 'escape' && C.vhttpd_workbench_menu_tracking() != 0 { return } }
	key := if os.user_os() != 'macos' { raw_key.replace('ctrl+', 'cmd+') } else { raw_key }
	mut app := unsafe { workshop }
	if route_workbench_menu_key(key) { ui2.consume_key(); return }
	if key in ['tab', 'shift+tab'] {
		target := next_focus_target(focus_targets(build_window()), workbench_focused_id(), key == 'shift+tab') or { return }
		ui2.consume_key()
		focus_workbench_target(target)
		ui2.refresh()
		return
	}
	match key {
		'cmd+enter', 'cmd+return' { if !app.desktop_update_open { submit_active_form() } }
		'escape' {
			if app.desktop_update_open { handle_event('desktop_update_back'); return }
			if app.show_remote && app.show_servers && app.server_snapshot.host_key.id != '' { handle_event('server_disconnect'); return }
			if app.show_remote && !app.show_servers && app.remote_snapshot.host_key.id != '' { handle_event('remote_disconnect'); return }
			if app.creating || app.server_busy || app.server_snapshot.busy || app.remote_snapshot.busy { return }
			if app.show_deployment { handle_event('deploy_close') }
			else if app.new_project { handle_event('new_cancel') }
			else if app.show_remote { handle_event('remote_close') }
			else if app.show_runtime { handle_event('runtime_close') }
			else if app.show_shared_relays { handle_event('shared_close') }
		}
		'cmd+w' { handle_event('quit') }
		else {}
	}
}

// Lists use Up/Down; page tabs use Left/Right. Moving selection reuses the
// same guarded event as a click and never activates destructive actions.
fn focus_selection_group(id string) string {
	for prefix in ['workspace_tab_', 'workspace_application_', 'project_', 'remote_select_', 'server_select_', 'shared_select_'] {
		if id.starts_with(prefix) { return prefix }
	}
	return ''
}

fn next_selection_target(targets []FocusTarget, current string, key ui2.KeyCode) ?FocusTarget {
	group := focus_selection_group(current)
	if group == '' { return none }
	horizontal := group == 'workspace_tab_'
	if (horizontal && key !in [.left, .right, .home, .end]) || (!horizontal && key !in [.up, .down, .home, .end]) { return none }
	members := targets.filter(focus_selection_group(it.id) == group && it.kind == .button)
	if members.len == 0 { return none }
	if key == .home { return members[0] }
	if key == .end { return members.last() }
	for i, member in members {
		if member.id == current {
			next := if key in [.left, .up] { if i > 0 { i - 1 } else { 0 } } else { if i + 1 < members.len { i + 1 } else { i } }
			return members[next]
		}
	}
	return none
}

fn workbench_focused_id() string {
	mut app := unsafe { workshop }
	native := ui2.focused_id()
	if native != '' {
		app.keyboard_navigation_focus = ''
		return native
	}
	return app.keyboard_navigation_focus
}

fn focus_workbench_target(target FocusTarget) {
	if target.scroll != '' { ui2.scroll_to_rect(target.scroll, target.frame.x, target.frame.y - 12, target.frame.width, target.frame.height + 24) }
	ui2.focus(target.id)
	mut app := unsafe { workshop }
	app.keyboard_navigation_focus = ''
	// The Linux immediate backend exposes native focus for editors only.
	// Keep other focus stops in the host and clear the old editor so typing
	// cannot accidentally continue in a field after tabbing onto a button.
	if ui2.focused_id() != target.id {
		ui2.dismiss_keyboard()
		app.keyboard_navigation_focus = target.id
	}
}

// NSTextField handles Escape itself unless it is consumed before the field
// editor. Tab keeps using ui2's text-command hook; editing keys remain native.
fn workbench_physical_key(event ui2.KeyEvent) {
	$if macos { if event.code == .escape && C.vhttpd_workbench_menu_tracking() != 0 { return } }
	mut app := unsafe { workshop }
	if app.environment_menu.open {
		if step := ui2.dropdown_menu_key(app.environment_menu_items(), app.environment_menu, event) {
			if step.chosen { app.reload_remote_profiles() }
			app.apply_environment_menu(step)
			ui2.consume_key()
			ui2.refresh()
		}
		return
	}
	$if linux {
		// The immediate backend has no native focusable combo box. Arrow keys
		// select its existing options through the same value/event as a click.
		if !event.cmd && !event.ctrl && !event.alt && event.code in [.up, .down, .home, .end] {
			for target in focus_targets(build_window()) {
				if target.id != workbench_focused_id() || target.kind != .dropdown || target.choices.len == 0 { continue }
				mut index := target.choices.index(target.value)
				if index < 0 { index = 0 }
				next := if event.code == .home { 0 } else if event.code == .end { target.choices.len - 1 } else if event.code == .up { if index > 0 { index - 1 } else { 0 } } else { if index + 1 < target.choices.len { index + 1 } else { index } }
				ui2.consume_key()
				ui2.set_text(target.id, target.choices[next])
				handle_event(target.action)
				focus_workbench_target(target)
				ui2.refresh()
				return
			}
		}
	}
	if event.code == .tab && !event.cmd && !event.ctrl && !event.alt {
		workbench_key(if event.shift { 'shift+tab' } else { 'tab' })
		return
	}
	if !event.cmd && !event.ctrl && !event.alt {
		if target := next_selection_target(all_focus_targets(build_window()), workbench_focused_id(), event.code) {
			ui2.consume_key()
			// Changing a runtime registration can stop the current local process.
			// Arrows only move focus in those lists; Enter/Space explicitly opens
			// the row. Page tabs and application details are presentation-only.
			group := focus_selection_group(target.id)
			if target.id != workbench_focused_id() && group in ['workspace_tab_', 'workspace_application_'] { handle_event(target.action) }
			focus_workbench_target(target)
			ui2.refresh()
			return
		}
	}
	if event.code == .escape {
		workbench_key('escape')
		ui2.consume_key()
		return
	}
	if event.code in [.space, .enter] && !event.cmd && !event.ctrl && !event.alt {
		for target in focus_targets(build_window()) {
			if target.id != workbench_focused_id() || target.kind !in [.button, .checkbox] { continue }
			ui2.consume_key()
			handle_event(target.action)
			for next in focus_targets(build_window()) { if next.id == target.id { focus_workbench_target(next); break } }
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
		if target.id in ids { handle_event(target.action); return }
	}
}

fn choice_button(id string, title string, x f64, y f64, width f64, selected bool, enabled bool) ui2.Element {
	return painted_button(id, title, ui2.rect(x, y, width, 34), ui2.BoxStyle{
		bg: if selected { workbench_colors.soft_accent } else { workbench_colors.paper }
		radius: 6
		border_color: if selected { workbench_colors.accent } else { workbench_colors.line }
		border_left: 1
		border_right: 1
		border_top: 1
		border_bottom: 1
	}, if !enabled { workbench_colors.disabled_foreground } else if selected { workbench_colors.accent } else { workbench_colors.ink }, enabled, .center, 6)
}

// Retry only on the UI thread and only while the destination field remains on
// the current page. focus() cannot target an immediate-mode field until the
// previous render has registered it; the regular refresh supplies that frame.
fn (mut app Workshop) restore_pending_form_focus(root ui2.Element) {
	if app.pending_form_focus == '' { return }
	if menu_focused_element(root, app.pending_form_focus) == none {
		app.pending_form_focus = ''
		return
	}
	ui2.focus(app.pending_form_focus)
	if ui2.focused_id() == app.pending_form_focus { app.pending_form_focus = '' }
}
