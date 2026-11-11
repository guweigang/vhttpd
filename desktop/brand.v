module main

import ui2

fn sidebar_brand(mark string) ui2.Element {
	// AppKit's Latin baseline in the bundled CJK face sits higher than the caption.
	title_y := $if macos {8.0} $else {0.0}
	return ui2.view('sidebar_brand',ui2.rect(20,20,176,42),ui2.BoxStyle{transparent:true},[
		ui2.Element{...ui2.image('brand_mark',mark,ui2.rect(0,-1,44,44)),accessibility_label:'vhttpd 品牌标志'},
		ui2.label('brand','vhttpd',ui2.rect(52,title_y,124,24),ui2.TextStyle{size:20,color:workbench_colors.ink,bold:true}),
		ui2.label('local_label','Desktop ' + desktop_version.all_before('-').all_before('+'),ui2.rect(52,22,124,17),ui2.TextStyle{size:11,color:workbench_colors.muted}),
	])
}
