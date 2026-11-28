module main

#flag -framework CoreText
#include <CoreText/CoreText.h>

fn C.vhttpd_workbench_register_font(&char) int

fn register_workbench_font(path string) ! {
	if C.vhttpd_workbench_register_font(path.str) == 0 { return error('无法加载工作台字体，请重新解压完整安装包。') }
}
