module main

import ui2

// Keep the native selection/keyboard behavior, while matching our text fields.
// AppKit's rounded popup bezel imposes a compact intrinsic height, so draw the
// field ourselves and let its borderless popup fill the entire hit area.
fn form_select(id string, title string, choices []string, frame ui2.Rect, enabled bool) ui2.Element {
	box := ui2.BoxStyle{
		bg: workbench_paper
		radius: 6
		border_color: if enabled && workbench_focused_id() == id { workbench_accent } else { workbench_line }
		border_left: 1
		border_right: 1
		border_top: 1
		border_bottom: 1
	}
	style := ui2.TextStyle{size: 13, color: if enabled { workbench_ink } else { workbench_muted }}
	$if macos {
		popup := ui2.Element{
			...ui2.dropdown(id, title, choices, ui2.rect(10, 0, frame.width - 20, frame.height), ui2.BoxStyle{transparent: true}, style)
			enabled: enabled
		}
		return ui2.view(id + '_field', frame, box, [popup])
	}
	return ui2.Element{...ui2.dropdown(id, title, choices, frame, box, style), enabled: enabled}
}
