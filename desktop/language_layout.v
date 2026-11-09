module main

import math
import ui2

struct WorkbenchTextLayout {
	text string
	lines int
	height f64
}

// Only label layout is cached, never editors or logs. Bound dynamic status
// strings too, so long-running monitoring cannot grow this cache indefinitely.
__global workbench_text_layout_cache = map[string]WorkbenchTextLayout{}

fn workbench_measure_style(style ui2.TextStyle) ui2.TextStyle {
	$if macos {return style}
	// Match linux_pixel_layout / windows_pixel_layout before measuring.
	return ui2.TextStyle{...style,size:style.size*0.75}
}

fn workbench_font_metrics(text string, style ui2.TextStyle) !ui2.LayoutSize {
	mut measured:=workbench_measure_style(style)
	$if windows {
		path:=if style.bold {workbench_bold_font_path} else {workbench_regular_font_path}
		if path!='' {measured=ui2.TextStyle{...measured,font_family:path}}
	}
	return ui2.measure_layout_text(text,ui2.TextStyle{...measured,lines:1},1000000)
}

fn workbench_label_width(text string, style ui2.TextStyle) f64 {
	measured:=workbench_measure_style(style)
	if ui2.text_measurement_exact() {
		mut width:=ui2.measure_text_width(text,measured)
		$if windows {width/=windows_display_scale()}
		return width
	}
	size:=workbench_font_metrics(text,style) or {return ui2.measure_text_width(text,measured)}
	return size.width
}

fn workbench_wrap_label(text string, style ui2.TextStyle, width f64) WorkbenchTextLayout {
	mut scale:=1.0
	$if windows {scale=windows_display_scale()}
	key:='${scale}|${ui2.text_measurement_exact()}|${style.font_family}|${style.size}|${style.bold}|${style.italic}|${width}|${text}'
	cacheable:=text.len<=2048
	if cacheable {if layout:=workbench_text_layout_cache[key] {return layout}}
	mut lines:=[]string{}
	for paragraph in text.split('\n') {
		mut remaining:=paragraph.runes()
		if remaining.len==0 {lines << '';continue}
		for remaining.len>0 {
			mut low:=1
			mut high:=remaining.len
			mut count:=1
			for low<=high {
				mid:=(low+high)/2
				if workbench_label_width(remaining[..mid].string(),style)<=width {
					count=mid;low=mid+1
				} else {high=mid-1}
			}
			// Prefer word boundaries in English; split CJK and long identifiers
			// only between UTF-8 runes. Explicit line breaks work on every backend.
			if count<remaining.len {
				for i:=count-1;i>0;i-- {
					if remaining[i]==` ` {count=i;break}
					// A CJK line may contain one early English word. Do not
					// rewind across CJK text to that word's distant space.
					if remaining[i]>=0x2e80 {
						if i<count-1 {count=i+1}
						break
					}
				}
			}
			// Keep closing CJK punctuation with preceding text rather than leaving
			// a full stop/bracket alone at the start of the following line.
			if count > 1 && count < remaining.len && remaining[count] in '。，、；：！？）】》〉」』’”'.runes() { count-- }
			lines << remaining[..count].string()
			remaining=remaining[count..].clone()
			if remaining.len>0 && remaining[0]==` ` {remaining=remaining[1..].clone()}
		}
	}
	metric:=workbench_font_metrics('Ag中',style) or {ui2.LayoutSize{height:style.size*1.4}}
	layout:=WorkbenchTextLayout{text:lines.join('\n'),lines:lines.len,height:math.ceil(metric.height*f64(lines.len))+4}
	if cacheable {
		if workbench_text_layout_cache.len>=512 {workbench_text_layout_cache.clear()}
		workbench_text_layout_cache[key]=layout
	}
	return layout
}

fn workbench_label_layout(element ui2.Element) ui2.Element {
	if element.kind!=.label || element.text=='' || element.frame.width<=4 || untranslated_ui_text(element.id) {return element}
	layout:=workbench_wrap_label(element.text,element.text_style,element.frame.width-2)
	if layout.lines<=1 && element.text_style.lines<=1 {return element}
	return ui2.Element{...element,text:layout.text,
		frame:ui2.Rect{...element.frame,height:math.max(element.frame.height,layout.height)},
		text_style:ui2.TextStyle{...element.text_style,lines:math.max(element.text_style.lines,layout.lines)}}
}

fn workbench_layout_overlay(child ui2.Element, parent ui2.Element) bool {
	return child.kind==.button && child.text=='' && child.frame.x==0 && child.frame.y==0
		&& child.frame.width>=parent.frame.width-1 && child.frame.height>=parent.frame.height-1
}

// Reflow original overlapping rows together. An expanded label moves later
// rows, while side-by-side controls remain aligned. Every build starts from
// source geometry, so switching languages never accumulates offsets.
fn workbench_text_layout(source ui2.Element) ui2.Element {
	if source.hidden {return source}
	element := workbench_button_rows(source)
	mut children:=[]ui2.Element{cap:element.children.len}
	mut order:=[]int{}
	for i,child in element.children {
		children << if workbench_painted_action(element) && child.id.ends_with('_caption') { workbench_action_caption(child) } else { workbench_text_layout(child) }
		if !child.hidden && !workbench_layout_overlay(child,element) {order << i}
	}
	for i in 1..order.len {
		mut j:=i
		for j>0 && element.children[order[j]].frame.y<element.children[order[j-1]].frame.y {
			order[j],order[j-1]=order[j-1],order[j];j--
		}
	}
	mut shift:=0.0
	mut old_end:=-1.0
	mut new_end:=-1.0
	for index in order {
		old:=element.children[index].frame
		// Source labels reserve a little more vertical space than their ink;
		// adjacent rows can therefore overlap by a few nominal pixels. Once a
		// row grows, separate its real multiline box from the next row too.
		if old.y>=old_end-8 {
			growth:=math.max(0.0,new_end-old_end)
			shift+=growth+if growth>0 {math.max(0.0,old_end+2-old.y)} else {0.0}
			old_end=old.y+old.height
			new_end=old.y+children[index].frame.height
		} else {
			old_end=math.max(old_end,old.y+old.height)
			new_end=math.max(new_end,old.y+children[index].frame.height)
		}
		child:=children[index]
		children[index]=ui2.Element{...child,frame:ui2.Rect{...child.frame,y:old.y+shift}}
	}
	mut height:=element.frame.height
	if element.kind==.view && height>0 && children.len>0 {
		mut old_bottom:=0.0
		mut bottom:=0.0
		for index in order {
			old:=element.children[index].frame
			old_bottom=math.max(old_bottom,old.y+old.height)
			child:=children[index].frame
			bottom=math.max(bottom,child.y+child.height)
		}
		height=math.max(height,bottom+math.min(12.0,math.max(0.0,height-old_bottom)))
		for i,child in element.children {
			if workbench_layout_overlay(child,element) {
				children[i]=ui2.Element{...children[i],frame:ui2.Rect{...children[i].frame,height:height}}
			}
		}
	}
	return workbench_label_layout(ui2.Element{...element,children:children,frame:ui2.Rect{...element.frame,height:height}})
}
