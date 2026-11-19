module main

import ui2

fn main() {
	ui2.run_window('运行包切换预览 · 多行验收', 760, 330, preview_view, preview_event)
}

fn preview_event(_ string) {}

fn preview_view() ui2.Element {
	return ui2.screen(0xffffff, [
		ui2.label('preview', '切换预览 · bodytest\n当前：vhttpd 0.1.0 · sha256-c4b76436e432\n目标：vhttpd 0.1.0 · sha256-741737d6dfd1\n确认后，该环境内全部应用将短暂停机并重启。', ui2.rect(24, 24, 712, 110), ui2.TextStyle{size: 14, color: 0x18202b, lines: 4}),
		ui2.button('confirm', '确认切换此环境…（仅展示）', ui2.rect(24, 148, 240, 36), ui2.BoxStyle{bg: 0x2460ef, radius: 6}, ui2.TextStyle{size: 14, color: 0xffffff}),
	])
}
