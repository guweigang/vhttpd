module main

import os

fn register_workbench_font(path string) ! {
	if !os.is_file(path) { return error('工作台字体文件不完整，请重新解压安装包。') }
}
