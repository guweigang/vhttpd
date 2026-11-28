module main

import os
import ui2

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
		'\n' + ui_text(app.environment_version_label()) + '\n\n© Bullsoft.org'
}

fn (app &Workshop) workbench_about_view(width f64) ui2.Element {
    dark := ui2.component_theme_mode_is_dark(workbench_appearance_mode, workbench_system_appearance)
    logo := os.join_path(os.dir(app.brand_mark), if dark { 'vhttpd-logo-light.png' } else { 'vhttpd-logo.png' })
    return ui2.screen(workbench_colors.paper, [
        button('about_back', '返回工作台', 24, 20, 132, false, true),
        ui2.view('about_brand', ui2.rect((width - 364) / 2, 88, 364, 149), ui2.BoxStyle{transparent: true}, [
            ui2.Element{...ui2.image('about_logo', logo, ui2.rect(24, 24, 316, 101)), accessibility_label: 'vhttpd'},
        ]),
        ui2.label('about_details', app.workbench_about_text(), ui2.rect(24, 250, width - 48, 220), ui2.TextStyle{size: 14, color: workbench_colors.ink, align: .center}),
    ])
}
