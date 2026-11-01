module ui2

import macos

fn test_explicit_line_breaks_are_not_collapsed_to_one_line() {
	_ = native_current_app()
	for text in [
		'切换预览 · bodytest\n当前：vhttpd 0.1.0 · build-old\n目标：vhttpd 0.1.0 · build-new\n确认后，该环境内全部应用将短暂停机并重启。',
		'First line\nSecond line',
		'First line\rSecond line',
	] {
		frame := NativeRect{width: 700, height: 110}
		view := native_new_label(frame, text, 0x18202b, 14, '', false, false, false, 0, 4, .top, false)
		assert !native_label_fits_one_line(view, frame)
		assert macos.msg_i64(view, 'maximumNumberOfLines') == 4
		native_update_label(view, frame, text, 0x18202b, 14, '', false, false, false, 0, 4, .top, false)
		assert macos.msg_i64(view, 'maximumNumberOfLines') == 4
		macos.release(view)
	}
}
