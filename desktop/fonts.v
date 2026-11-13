module main

import os
import ui2

const workbench_ui_font = 'Sarasa Term SC'
const workbench_mono_font = workbench_ui_font

__global workbench_regular_font_path = ''
__global workbench_bold_font_path = ''

fn workbench_fonts_dir() !string {
	base := os.dir(os.executable())
	mut directory := os.join_path(base, 'fonts')
	$if macos {
		directory = os.join_path(base, '..', 'Resources', 'fonts')
	}
	$if windows {
		directory = os.join_path(base, 'resources', 'fonts')
	}
	if os.is_file(os.join_path(directory, 'fonts.lock.json')) { return os.real_path(directory) }

	return error('字体资源缺失，请重新解压完整工作台安装包。')
}

fn configure_workbench_fonts() ! {
	directory := workbench_fonts_dir()!
	for role, path in load_workbench_fonts(directory)! {
		register_workbench_font(path)!
		if role == 'regular' { workbench_regular_font_path = path }
		if role == 'bold' { workbench_bold_font_path = path }
	}
	$if linux {
		// The custom renderer reads the same packaged faces directly.
		os.setenv('UI2_FONT', workbench_regular_font_path, true)
		os.setenv('UI2_FONT_BOLD', workbench_bold_font_path, true)
	}
}

fn workbench_font_layout(element ui2.Element) ui2.Element {
	mut children := []ui2.Element{cap: element.children.len}
	for child in element.children { children << workbench_font_layout(child) }
	mut family := if element.text_style.font_family in ['Menlo', 'Consolas', 'monospace', 'mono',
		'Roboto Mono', '', 'Microsoft YaHei UI', 'Segoe UI', workbench_ui_font] {
		workbench_ui_font
	} else {
		element.text_style.font_family
	}
	$if linux {
		if family == workbench_ui_font && workbench_regular_font_path != '' {
			family = if element.text_style.bold {
				workbench_bold_font_path
			} else {
				workbench_regular_font_path
			}
		}
	}
	size := if element.text_style.size < 12 {
		12.0
	} else if element.text_style.size < 14 {
		14.0
	} else {
		element.text_style.size
	}
	return ui2.Element{ ...element, children: children, text_style: ui2.TextStyle{ ...element.text_style, size: size, font_family: family } }
}
