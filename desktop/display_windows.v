module main

import ui2
import os

fn C.vhttpd_workbench_prepare_windows_display()
fn C.vhttpd_workbench_windows_scale() f64

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
	mut children := []ui2.Element{cap: element.children.len}
	for child in element.children { children << windows_pixel_layout(child, scale) }
	pixel_size := if element.text_style.size < 12 {
		12.0
	} else if element.text_style.size < 14 {
		14.0
	} else {
		element.text_style.size
	}
	family := if element.text_style.font_family in ['Menlo', 'monospace', 'mono'] {
		'Consolas'
	} else if element.text_style.font_family == '' {
		'Microsoft YaHei UI'
	} else {
		element.text_style.font_family
	}
	return ui2.Element{
		...element
		frame:        ui2.rect(element.frame.x * scale, element.frame.y * scale, element.frame.width * scale, element.frame.height * scale)
		text_style:   ui2.TextStyle{ ...element.text_style, size: pixel_size * 0.75, font_family: family }
		box:          ui2.BoxStyle{ ...element.box, radius: element.box.radius * scale, border_left: element.box.border_left * scale, border_top: element.box.border_top * scale, border_right: element.box.border_right * scale, border_bottom: element.box.border_bottom * scale }
		padding_left: element.padding_left * scale
		padding:      element.padding * scale
		children:     children
	}
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
	chosen := C.vhttpd_workbench_choose_environment(ui2.native_window_handle(), labels.data, labels.len, current, int(16 * scale), int(116 * scale))
	if chosen > 0 && chosen <= choices.len && app.can_switch_environment() {
		app.reload_remote_profiles()
		app.open_environment_projects(choices[chosen - 1].id)
	}
}
