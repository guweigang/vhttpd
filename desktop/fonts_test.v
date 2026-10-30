module main

import ui2

fn test_font_layout_uses_shared_faces_without_changing_geometry() {
	root := ui2.screen(workbench_paper, [label('heading', '项目 Project 状态', 0, 0, 300, 24, workbench_ink),
		ui2.text_area('logs', 'HTTP latency 123 ms', ui2.rect(0, 80, 300, 100), ui2.BoxStyle{}, ui2.TextStyle{font_family: 'Menlo', size: 11})])
	adapted := workbench_font_layout(root)
	assert adapted.children[0].text_style.font_family == workbench_ui_font
	assert adapted.children[1].text_style.font_family == workbench_mono_font
	assert adapted.children[1].text_style.size == 12
	assert adapted.children[0].frame == root.children[0].frame
	assert adapted.children[0].text == root.children[0].text
	assert adapted.children[1].frame == root.children[1].frame
}
