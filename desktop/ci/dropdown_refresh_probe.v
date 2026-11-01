module main

import time
import ui2

__global dropdown_probe_selection = 'bodytest'
__global dropdown_probe_frames = 0
__global dropdown_probe_changes = 0

fn main() {
	spawn refresh_loop()
	ui2.run_window('运行环境选择 · 鼠标验收', 620, 320, probe_view, probe_event)
}

fn refresh_loop() {
	for {
		time.sleep(500 * time.millisecond)
		ui2.request_refresh()
	}
}

fn probe_event(event string) {
	if event == 'environment' {
		dropdown_probe_selection = ui2.text(event)
		dropdown_probe_changes++
	}
	ui2.refresh()
}

fn probe_view() ui2.Element {
	dropdown_probe_frames++
	return ui2.screen(0xffffff, [
		ui2.label('title', '选择运行环境（每 500 毫秒刷新）', ui2.rect(24, 24, 570, 32), ui2.TextStyle{size: 18}),
		ui2.dropdown('environment', dropdown_probe_selection, ['bodytest', 'desktop-e2e-fc222a92', 'hello-vjsx'], ui2.rect(24, 80, 570, 36), ui2.BoxStyle{bg: 0xf3f5f8}, ui2.TextStyle{size: 14}),
		ui2.label('result', '当前环境：${dropdown_probe_selection}；选中事件：${dropdown_probe_changes}', ui2.rect(24, 144, 570, 36), ui2.TextStyle{size: 16}),
		ui2.label('frames', '刷新次数：${dropdown_probe_frames}', ui2.rect(24, 200, 570, 32), ui2.TextStyle{size: 14}),
	])
}
