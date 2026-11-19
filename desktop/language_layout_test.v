module main

import os
import ui2

fn language_layout_fonts() ! {
	$if macos {
		for _,path in load_workbench_fonts(os.join_path(@VMODROOT,'desktop/bin/vhttpd-workbench.app/Contents/Resources/fonts'))! {register_workbench_font(path)!}
	}
}

fn test_long_localized_labels_move_following_rows_and_preserve_values() ! {
	language_layout_fonts()!
	root:=ui2.view('form',ui2.rect(0,0,220,80),ui2.BoxStyle{},[
		label('intro','Choose an environment before installing apps and configuring shared resources.',0,0,200,14,workbench_colors.ink),
		input('value','原始配置值','',0,24,200,true),
	])
	result:=workbench_text_layout(root)
	assert result.children[0].text_style.lines>1
	assert result.children[1].frame.y>=result.children[0].frame.y+result.children[0].frame.height
	assert result.frame.height>=result.children[1].frame.y+result.children[1].frame.height
	assert result.children[1].text=='原始配置值'
	assert workbench_text_layout(root)==result
	assert workbench_text_layout(result)==result
}

fn test_single_line_buttons_wrap_as_controls_and_preserve_hit_areas() ! {
	language_layout_fonts()!
	root:=ui2.view('actions',ui2.rect(0,0,240,90),ui2.BoxStyle{},[
		button('long','Manage runtime packages',0,0,100,false,true),
		button('short','Back',112,0,100,false,false),
		label('after','Next row',0,42,200,14,workbench_colors.ink),
	])
	result:=workbench_text_layout(root)
	first:=result.children[0]
	assert first.frame.height==34
	assert first.children[0].text_style.lines==1
	assert first.children[1].frame.height==first.frame.height
	assert first.children[1].enabled
	assert !result.children[1].children[1].enabled
	assert first.frame.y+first.frame.height<result.children[1].frame.y
	assert result.children[2].frame.y>=result.children[1].frame.y+result.children[1].frame.height
}

fn test_mixed_cjk_text_wraps_without_broken_utf8_or_growing_log_editors() ! {
	language_layout_fonts()!
	text:='这是没有空格的中文说明并且包含English和数据库资源。'
	style:=ui2.TextStyle{size:14,font_family:workbench_ui_font}
	wrapped:=workbench_wrap_label(text,style,110)
	assert wrapped.lines>1
	mixed:=workbench_wrap_label('项目中的 Relay 配置仍保留。启动本地运行环境后，再检查连接并开启指定账号接管。',style,456)
	assert mixed.text.split('\n')[0].runes().len>20
	assert wrapped.text.replace('\n','')==text
	for line in wrapped.text.split('\n') {assert workbench_label_width(line,style)<=110}
	logs:=workspace_text('raw_logs','运行环境\nOriginal output 原始日志',0,200,70)
	assert workbench_text_layout(logs)==logs
	name:=label('workspace_title','这是用户填写的运行环境名称',0,0,60,14,workbench_colors.ink)
	assert workbench_text_layout(name)==name
}

fn test_localized_label_cache_stays_bounded_for_dynamic_statuses() ! {
	language_layout_fonts()!
	for i in 0..600 {workbench_wrap_label('Dynamic UI status ${i}',ui2.TextStyle{size:14,font_family:workbench_ui_font},130)}
	assert workbench_text_layout_cache.len<=512
}
