module main

import math
import ui2

fn workbench_painted_action(element ui2.Element) bool {
	return element.kind == .view && element.id.ends_with('_container')
		&& element.children.any(it.id == element.id.all_before_last('_container') + '_caption')
		&& element.children.any(it.kind == .button && it.text == '')
}

fn workbench_action_width(element ui2.Element) f64 {
	for child in element.children {
		if child.kind == .label && child.id.ends_with('_caption') {
			return math.ceil(workbench_label_width(child.text, child.text_style)) + child.frame.x * 2 + 12
		}
	}
	return element.frame.width
}

fn workbench_action_frame(element ui2.Element, frame ui2.Rect) ui2.Element {
	mut children := element.children.clone()
	for i, child in children {
		if child.kind == .button || child.id.ends_with('_caption') {
			children[i] = ui2.Element{...child, frame: ui2.Rect{...child.frame, width: frame.width - child.frame.x * 2, height: frame.height}}
		}
	}
	return ui2.Element{...element, frame: frame, children: children}
}

// Buttons keep single-line titles. Resize the control before wrapping an action
// row; never wrap its caption independently from its native hit area.
fn workbench_button_rows(element ui2.Element) ui2.Element {
	if element.frame.width <= 0 || element.children.len == 0 || workbench_painted_action(element) { return element }
	// Navigation and selector rows have a fixed column; their labels may truncate.
	if element.id in ['workbench_sidebar', 'server_selector', 'shared_selector']
		|| element.id.ends_with('_selector') || element.id.ends_with('_list') { return element }
	available := element.frame.width - if element.kind == .scroll && element.id.ends_with('_page') { 30.0 } else { 0.0 }
	mut children := element.children.clone()
	mut order := []int{}
	for i, child in children { if !child.hidden { order << i } }
	for i in 1 .. order.len {
		mut j := i
		for j > 0 && (children[order[j]].frame.y < children[order[j-1]].frame.y || (children[order[j]].frame.y == children[order[j-1]].frame.y && children[order[j]].frame.x < children[order[j-1]].frame.x)) {
			order[j], order[j-1] = order[j-1], order[j]
			j--
		}
	}
	mut cursor := 0
	mut shift := 0.0
	for cursor < order.len {
		y := element.children[order[cursor]].frame.y
		mut end := cursor + 1
		for end < order.len && element.children[order[end]].frame.y == y { end++ }
		indices := order[cursor..end]
		all_actions := indices.all(workbench_painted_action(element.children[it]))
		mut x := element.children[indices[0]].frame.x
		row_start := x
		mut row_y := y + shift
		mut row_height := 0.0
		for index in indices {
			original := element.children[index]
			mut frame := ui2.Rect{...original.frame, y: original.frame.y + shift}
			if workbench_painted_action(original) {
				needed := math.min(if indices.len == 1 { available } else { available - row_start }, math.max(original.frame.width, workbench_action_width(original)))
				if all_actions {
					// A single trailing action can grow left into available space.
					// Do not cap it to its old narrow frame and ellipsize the title.
					if indices.len == 1 {
						x = math.min(original.frame.x, available - needed)
					} else if row_y == y + shift {
						// Preserve intentional gaps and trailing primary actions when
						// the row already fits; only shift controls to avoid overlap.
						x = math.max(x, original.frame.x)
					}
					if indices.len > 1 && x > row_start && x + needed > available {
						row_y += row_height + 10
						x = row_start
						row_height = 0
					}
					frame = ui2.Rect{x: x, y: row_y, width: needed, height: original.frame.height}
					x += needed + 12
					row_height = math.max(row_height, frame.height)
				} else {
					// Header actions stay aligned with the trailing edge.
					width := math.min(available, math.max(original.frame.width, workbench_action_width(original)))
					frame = ui2.Rect{...frame, x: math.min(frame.x, available - width), width: width}
				}
				children[index] = workbench_action_frame(original, frame)
			} else { children[index] = ui2.Element{...original, frame: frame} }
		}
		if all_actions { shift = row_y - y }
		cursor = end
	}
	return ui2.Element{...element, children: children, frame: ui2.Rect{...element.frame, height: element.frame.height + if element.kind == .view { shift } else { 0.0 }}}
}

fn workbench_action_caption(element ui2.Element) ui2.Element {
	mut text := element.text.replace('\n', ' ')
	if workbench_label_width(text, element.text_style) > element.frame.width - 2 {
		mut runes := text.runes()
		for runes.len > 0 && workbench_label_width(runes.string() + '…', element.text_style) > element.frame.width - 2 {
			runes = runes[..runes.len-1]
		}
		text = runes.string() + '…'
	}
	return ui2.Element{...element, text: text, text_style: ui2.TextStyle{...element.text_style, lines: 1}}
}
