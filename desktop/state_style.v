module main

import ui2

const workbench_warning = u32(0x925b10)
const workbench_danger = u32(0xb42318)

fn state_colors(tone string) (u32, u32) {
	return match tone {
		'warning' { u32(0xfff8eb), workbench_warning }
		'danger' { u32(0xfff2f0), workbench_danger }
		'good' { u32(0xedf7f0), workbench_green }
		else { workbench_soft_accent, workbench_accent }
	}
}

fn state_notice(id string, title string, detail string, frame ui2.Rect, tone string) ui2.Element {
	bg, ink := state_colors(tone)
	return ui2.view(id, frame, ui2.BoxStyle{bg: bg, radius: 8, border_color: ink, border_left: 3}, [
		ui2.label(id + '_title', title, ui2.rect(16, 11, frame.width - 32, 24), ui2.TextStyle{size: 13, bold: true, color: ink}),
		ui2.label(id + '_detail', detail, ui2.rect(16, 39, frame.width - 32, frame.height - 48), ui2.TextStyle{size: 12, color: workbench_muted, lines: 3}),
	])
}
