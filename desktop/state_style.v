module main

import ui2

fn state_colors(tone string) (u32, u32) {
	return match tone {
		'warning' { workbench_colors.warning_background, workbench_colors.warning }
		'danger' { workbench_colors.danger_background, workbench_colors.danger }
		'good' { workbench_colors.good_background, workbench_colors.green }
		else { workbench_colors.soft_accent, workbench_colors.accent }
	}
}

fn state_notice(id string, title string, detail string, frame ui2.Rect, tone string) ui2.Element {
	bg, ink := state_colors(tone)
	return ui2.view(id, frame, ui2.BoxStyle{bg: bg, radius: 8, border_color: ink, border_left: 3}, [
		ui2.label(id + '_title', title, ui2.rect(16, 11, frame.width - 32, 24), ui2.TextStyle{size: 13, bold: true, color: ink}),
		ui2.label(id + '_detail', detail, ui2.rect(16, 39, frame.width - 32, frame.height - 48), ui2.TextStyle{size: 12, color: workbench_colors.muted, lines: 3}),
	])
}
