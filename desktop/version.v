module main

// The default is embedded; packages override it at compile time with the exact
// tag/development version, never with the bundled or remote vhttpd version.
const desktop_base_version = $embed_file('version.txt').to_string().trim_space()
const desktop_version = compiled_desktop_version()

fn compiled_desktop_version() string {
	override := $d('vhttpd_desktop_version', '')
	return if override != '' { override } else { desktop_base_version }
}

fn (app &Workshop) workbench_about_text() string {
	return 'vhttpd Workbench\nDesktop ' + desktop_version +
		ui_text('\n基于 V / ui2 的开发工作台\n\n当前环境：') + ui_text(app.environment_name()) +
		'\n' + ui_text(app.environment_version_label())
}
