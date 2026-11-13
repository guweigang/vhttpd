@[has_globals]
module main

import os
import time
import ui2

#include <windows.h>
#include "@VMODROOT/desktop/ci/windows_display_probe.h"

fn C.vhttpd_probe_unchanged_children(voidptr, int) int
fn C.vhttpd_probe_edit_needs_repaint(voidptr) int

__global (
	calls          int
	first_count    int
	initial_frames u64
	polling        bool
	local_change   int
)

fn build_probe() ui2.Element {
	calls++
	frames, skipped := ui2.windows_poll_refresh_stats()
	if polling && calls - first_count == 6 && (frames != initial_frames || skipped < 4) {
		panic('unchanged polling repainted native controls')
	}
	if polling && calls - first_count == 9 {
		if frames != initial_frames + 1 {
			panic('changed polling failed to update native controls')
		}
		os.write_file(os.getenv('VHTTPD_WINDOWS_PROBE_READY'), 'native HWND, unchanged explicit refresh, isolated caption/page repaint, and unchanged/changed polling passed') or { panic(err) }
	}
	return ui2.screen(0xffffff, [
		ui2.label(if local_change == 2 { 'other-page-title' } else { 'title' }, if polling && calls - first_count >= 6 {
			'Updated · 更新'
		} else {
			if local_change == 1 { 'Changed · 已修改' } else { 'Stable · 稳定' }
		}, ui2.rect(20, 20, 550, 40), ui2.TextStyle{ size: 15 }),
		ui2.text_field('input', 'editable', '', ui2.rect(20, 80, 400, 36), ui2.BoxStyle{}, ui2.TextStyle{}, 0),
	])
}

fn event(_ string) {}

fn ready(handle voidptr) {
	if C.vhttpd_probe_unchanged_children(handle, 1) < 2 {
		panic('native refresh probe has no controls')
	}
	ui2.refresh()
	if C.vhttpd_probe_unchanged_children(handle, 0) != 0 {
		panic('unchanged explicit refresh invalidated native controls')
	}
	for change in [1, 2] {
		C.vhttpd_probe_unchanged_children(handle, 1)
		local_change = change
		ui2.refresh()
		if C.vhttpd_probe_unchanged_children(handle, 0) == 0 {
			panic('changed caption did not request repaint')
		}
		if C.vhttpd_probe_edit_needs_repaint(handle) != 0 {
			panic('caption or page update invalidated an unrelated native input')
		}
	}
	first_count = calls
	frames, _ := ui2.windows_poll_refresh_stats()
	initial_frames = frames
	polling = true
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
