module main

import os
import ui2

const workbench_ui_font = 'Noto Sans CJK SC'
const workbench_mono_font = 'Roboto Mono'

fn workbench_fonts_dir() !string {
	base := os.dir(os.executable())
	for directory in [os.join_path(base, '..', 'Resources', 'fonts'), os.join_path(base, 'resources', 'fonts'), os.join_path(base, 'fonts')] {
		if os.is_file(os.join_path(directory, 'NotoSansCJKsc-Regular.otf')) && os.is_file(os.join_path(directory, 'NotoSansCJKsc-Bold.otf')) {
			return os.real_path(directory)
		}
	}
	return error('字体资源缺失，请重新解压完整工作台安装包。')
}

fn configure_workbench_fonts() ! {
	directory := workbench_fonts_dir()!
	for name in ['NotoSansCJKsc-Regular.otf', 'NotoSansCJKsc-Bold.otf', 'RobotoMono-Regular.ttf', 'RobotoMono-Bold.ttf'] {
		register_workbench_font(os.join_path(directory, name))!
	}
	$if linux {
		// The custom renderer reads the same packaged faces directly.
		os.setenv('UI2_FONT', os.join_path(directory, 'NotoSansCJKsc-Regular.otf'), true)
		os.setenv('UI2_FONT_BOLD', os.join_path(directory, 'NotoSansCJKsc-Bold.otf'), true)
	}
}

fn workbench_font_layout(element ui2.Element) ui2.Element {
	mut children := []ui2.Element{cap: element.children.len}
	for child in element.children { children << workbench_font_layout(child) }
	family := if element.text_style.font_family in ['Menlo', 'Consolas', 'monospace', 'mono', 'Roboto Mono'] {
		workbench_mono_font
	} else if element.text_style.font_family in ['', 'Microsoft YaHei UI', 'Segoe UI'] {
		workbench_ui_font
	} else { element.text_style.font_family }
	size := if element.text_style.size < 12 { 12.0 } else if element.text_style.size < 14 { 14.0 } else { element.text_style.size }
	return ui2.Element{...element, children: children, text_style: ui2.TextStyle{...element.text_style, size: size, font_family: family}}
}
