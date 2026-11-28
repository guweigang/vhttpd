module main

fn C.vhttpd_workbench_register_font_windows(&u16) int

fn register_workbench_font(path string) ! {
	wide := path.to_wide()
	defer { unsafe { free(wide) } }
	if C.vhttpd_workbench_register_font_windows(wide) == 0 { return error('无法加载工作台字体，请重新解压完整安装包。') }
}
