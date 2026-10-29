@[has_globals]
module main

import os
import time
import ui2

__global calls int

fn build_probe() ui2.Element {
	calls++
	frames, skipped := ui2.windows_poll_refresh_stats()
	if calls == 7 && (frames != 1 || skipped < 4) {
		panic('unchanged polling repainted native controls')
	}
	if calls == 10 {
		if frames != 2 { panic('changed polling failed to update native controls') }
		os.write_file(os.getenv('VHTTPD_WINDOWS_PROBE_READY'), 'native HWND and unchanged/changed refresh passed') or { panic(err) }
	}
	return ui2.screen(0xffffff, [
		ui2.label('title', if calls >= 7 { 'Updated · 更新' } else { 'Stable · 稳定' }, ui2.rect(20, 20, 550, 40), ui2.TextStyle{ size: 15 }),
		ui2.text_field('input', 'editable', '', ui2.rect(20, 80, 400, 36), ui2.BoxStyle{}, ui2.TextStyle{}, 0),
	])
}

fn event(_ string) {}

fn ready(_ voidptr) {
	spawn poll_probe()
}

fn poll_probe() {
	for _ in 0 .. 12 {
		time.sleep(100 * time.millisecond)
		ui2.request_poll_refresh()
	}
}

fn main() {
	ui2.on_window_ready(ready)
	ui2.run_window('Windows repaint probe', 640, 320, build_probe, event)
}
