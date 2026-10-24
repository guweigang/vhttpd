module main

import macos

fn bring_workbench_forward() {
	app := macos.msg_id(macos.get_class('NSApplication'), 'sharedApplication')
	mut window := macos.msg_id(app, 'mainWindow')
	if window == unsafe { nil } {
		windows := macos.msg_id(app, 'windows')
		if macos.msg_u64(windows, 'count') > 0 { window = macos.msg_id_u64(windows, 'objectAtIndex:', 0) }
	}
	macos.msg_void1(window, 'deminiaturize:', unsafe { nil })
	macos.msg_void1(window, 'makeKeyAndOrderFront:', unsafe { nil })
	macos.msg_void_bool(app, 'activateIgnoringOtherApps:', true)
}
