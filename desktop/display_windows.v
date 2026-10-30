module main

import ui2
import os

fn C.vhttpd_workbench_prepare_windows_display()
fn C.vhttpd_workbench_windows_scale() f64
fn C.vhttpd_workbench_field_line_height() f64

fn windows_display_scale() f64 {
	return C.vhttpd_workbench_windows_scale()
}

// Layout stays in logical pixels. Win32 fonts consume points and already apply
// system DPI, whereas native child frames consume physical pixels.
fn windows_pixel_layout(original ui2.Element, scale f64) ui2.Element {
	mut element := original
	// Native view buttons retain all captions/badges without an empty Win32
	// BUTTON painting over its sibling labels. ui2 supplies keyboard and AX actions.
	if element.kind == .view && element.children.len > 0 {
		hit := element.children.last()
		if hit.kind == .button && hit.text == '' && hit.box.transparent && hit.frame.x == 0 && hit.frame.y == 0 && hit.frame.width == element.frame.width && hit.frame.height == element.frame.height {
			element = ui2.Element{ ...element, id: hit.id, action_id: hit.action_id, button_behavior: true, enabled: element.enabled && hit.enabled, accessibility_role: 'button', accessibility_label: hit.accessibility_label, children: element.children[..element.children.len - 1].clone() }
		}
	}
	// The desktop's compact action row has one Windows control height.
	if element.kind == .view && element.button_behavior && element.frame.height == 34 {
		mut captions := []ui2.Element{cap: element.children.len}
		for child in element.children {
			captions << if child.kind == .label && child.frame.y == 0 && child.frame.height == 34 {
				ui2.Element{...child, frame: ui2.rect(child.frame.x, 0, child.frame.width, 36)}
			} else { child }
		}
		element = ui2.Element{...element, frame: ui2.rect(element.frame.x, element.frame.y, element.frame.width, 36), children: captions}
	}
	if element.kind == .view && element.button_behavior && element.enabled && ui2.focused_id() == element.id {
		element = ui2.Element{...element, box: ui2.BoxStyle{...element.box, radius: 6, border_color: workbench_accent, border_left: 2, border_top: 2, border_right: 2, border_bottom: 2}}
	}
	mut children := []ui2.Element{cap: element.children.len}
	for child in element.children { children << windows_pixel_layout(child, scale) }
	pixel_size := if element.kind == .text_field {
		14.0
	} else if element.text_style.size < 12 {
		12.0
	} else if element.text_style.size < 14 {
		14.0
	} else {
		element.text_style.size
	}
	family := if element.text_style.font_family in ['Menlo', 'monospace', 'mono'] {
		workbench_mono_font
	} else if element.text_style.font_family == '' {
		workbench_ui_font
	} else {
		element.text_style.font_family
	}
	adapted := ui2.Element{
		...element
		frame:        ui2.rect(element.frame.x * scale, element.frame.y * scale, element.frame.width * scale, element.frame.height * scale)
		text_style:   ui2.TextStyle{ ...element.text_style, size: pixel_size * 0.75, font_family: family }
		box:          ui2.BoxStyle{ ...element.box, bg: if element.kind == .checkbox { workbench_paper } else { element.box.bg }, radius: element.box.radius * scale, border_left: element.box.border_left * scale, border_top: element.box.border_top * scale, border_right: element.box.border_right * scale, border_bottom: element.box.border_bottom * scale }
		padding_left: (if element.kind in [.text_field, .text_area] && element.padding_left < 10 { 10.0 } else { element.padding_left }) * scale
		padding:      element.padding * scale
		children:     children
	}
	if element.kind != .text_field { return adapted }
	// A single-line EDIT always draws at the top of its native client rect.
	// Keep its native input semantics and centre that rect inside the full field.
	height := if adapted.frame.height < 36 * scale { 36 * scale } else { adapted.frame.height }
	measured := C.vhttpd_workbench_field_line_height() * scale
	line_height := if measured > height - 8 * scale { height - 8 * scale } else { measured }
	inset := 10 * scale
	field := ui2.Element{
		...adapted
		frame: ui2.rect(inset, (height - line_height) / 2, adapted.frame.width - inset * 2, line_height)
		box: ui2.BoxStyle{bg: element.box.bg}
		padding_left: 0
	}
	focused := element.enabled && ui2.focused_id() == element.id
	border := if focused { 2.0 * scale } else { scale }
	return ui2.Element{
		...ui2.view('windows_field_${element.id}', ui2.rect(adapted.frame.x, adapted.frame.y, adapted.frame.width, height),
			ui2.BoxStyle{...adapted.box, radius: 6 * scale, border_color: if focused { workbench_accent } else { element.box.border_color }, border_left: border, border_top: border, border_right: border, border_bottom: border}, [field])
		enabled: element.enabled
		hidden: element.hidden
		clickable: !element.readonly
		cursor: 'text'
	}
}

fn handle_windows_field_event(event string) bool {
	prefix := 'pointer:down:windows_field_'
	if !event.starts_with(prefix) { return event.starts_with('pointer:up:windows_field_') }
	id := event[prefix.len..].all_before(':')
	if id != '' { ui2.focus(id); ui2.refresh() }
	return true
}

fn windows_brand_asset(path string) string {
	percent := int(windows_display_scale() * 100 + 0.5)
	candidate := path.replace('.bmp', '-${percent}.bmp')
	return if percent != 100 && os.is_file(candidate) { candidate } else { path }
}

fn C.vhttpd_workbench_choose_environment(voidptr, voidptr, int, int, int, int) int

fn (mut app Workshop) choose_windows_environment() {
	app.environment_menu = ui2.DropdownMenuState{}
	if !app.can_switch_environment() { return }
	choices := app.environment_choices()
	mut labels := []&u16{cap: choices.len}
	mut current := -1
	for i, choice in choices {
		labels << choice.title.replace('&', '&&').to_wide()
		if choice.id == app.environment_id { current = i }
	}
	defer {
		for label in labels {
			unsafe { free(label) }
		}
	}
	scale := windows_display_scale()
	chosen := C.vhttpd_workbench_choose_environment(ui2.native_window_handle(), labels.data, labels.len, current, int(16 * scale), int(122 * scale))
	if chosen > 0 && chosen <= choices.len && app.can_switch_environment() {
		app.reload_remote_profiles()
		app.open_environment_projects(choices[chosen - 1].id)
	}
}
