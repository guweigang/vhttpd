module ui2

import macos

fn test_styled_inputs_disable_exterior_ring_without_changing_box_geometry() {
	_ = native_current_app()
	box := BoxStyle{bg: 0xffffff, radius: 6, border_color: 0xe0e7f0, border_left: 1, border_right: 1, border_top: 1, border_bottom: 1}
	for secure in [false, true] {
		el := Element{...text_field('field', '', 'sample', rect(0, 0, 360, 36), box, TextStyle{size: 14}, 0), secure: secure}
		field := native_new_text_field(el)
		// Borders are applied by the render pass after the control is styled.
		native_set_box_borders(field, box)
		assert macos.msg_u64(field, 'focusRingType') == 1
		layer := macos.msg_id(field, 'layer')
		assert macos.msg_f64(layer, 'borderWidth') == 1
		assert macos.msg_f64(layer, 'cornerRadius') == 6
		native_update_text_field(field, element_rect(el.frame), '', 'sample', BoxStyle{...box, border_color: 0x2563eb}, 0x17202a, 14, false, false, true, .left, 12)
		assert macos.msg_u64(field, 'focusRingType') == 1
		assert macos.msg_f64(layer, 'borderWidth') == 1
		assert macos.msg_f64(layer, 'cornerRadius') == 6
		// Fields using the native bezel keep AppKit's normal focus behavior.
		native_update_text_field(field, element_rect(el.frame), '', 'sample', BoxStyle{}, 0x17202a, 14, false, false, true, .left, 12)
		assert macos.msg_u64(field, 'focusRingType') == 0
		macos.release(field)
	}
}
