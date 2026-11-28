module main

import os
import ui2

fn (app &Workshop) workbench_about_view(width f64) ui2.Element {
    dark := ui2.component_theme_mode_is_dark(workbench_appearance_mode, workbench_system_appearance)
    logo := os.join_path(os.dir(app.brand_mark), if dark { 'vhttpd-logo-light.png' } else { 'vhttpd-logo.png' })
    return ui2.screen(workbench_colors.paper, [
        button('about_back', '返回工作台', 24, 20, 132, false, true),
        ui2.view('about_brand', ui2.rect((width - 364) / 2, 88, 364, 149), ui2.BoxStyle{transparent: true}, [
            ui2.Element{...ui2.image('about_logo', logo, ui2.rect(24, 24, 316, 101)), accessibility_label: 'vhttpd'},
        ]),
        ui2.label('about_product', 'vhttpd desktop ' + desktop_version, ui2.rect(24, 246, width - 48, 34), ui2.TextStyle{size: 18, bold: true, color: workbench_colors.ink, align: .center}),
        ui2.label('about_release', ui_text('发布于 {0}').replace('{0}', desktop_release_date()), ui2.rect(24, 286, width - 48, 24), ui2.TextStyle{size: 13, color: workbench_colors.muted, align: .center}),
        ui2.label('about_powered', 'Powered by vlang & ui2', ui2.rect(24, 326, width - 48, 22), ui2.TextStyle{size: 12, color: workbench_colors.muted, align: .center}),
        ui2.label('about_copyright', '© Bullsoft.org', ui2.rect(24, 370, width - 48, 22), ui2.TextStyle{size: 12, color: workbench_colors.muted, align: .center}),
    ])
}
