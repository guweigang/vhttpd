module ui2

import macos

fn test_dropdown_refresh_preserves_menu_items_and_pending_native_selection() {
	_ = native_current_app()
	el := dropdown('environment', 'bodytest', ['bodytest', 'other'], rect(0, 0, 360, 36), BoxStyle{}, TextStyle{size: 14})
	popup := native_new_dropdown(el)
	defer { macos.release(popup) }
	first_item := macos.msg_id_u64(popup, 'itemAtIndex:', 0)
	// During mouse tracking AppKit changes the native selection before the
	// action callback has committed it to the declarative model.
	native_select_dropdown_item(popup, 'other')
	for _ in 0 .. 20 {
		native_update_dropdown(popup, el, false)
		assert macos.msg_id_u64(popup, 'itemAtIndex:', 0) == first_item
		assert native_dropdown_text(popup) == 'other'
	}
	// An explicit model change must still update the native control.
	native_update_dropdown(popup, el, true)
	assert native_dropdown_text(popup) == 'bodytest'
	// Replacing options, including renaming without changing their count,
	// must update the menu and apply the declared selection.
	renamed := dropdown('environment', 'renamed', ['bodytest', 'renamed'], el.frame, BoxStyle{}, TextStyle{size: 14})
	native_update_dropdown(popup, renamed, false)
	assert native_dropdown_text(popup) == 'renamed'
	shorter := dropdown('environment', 'bodytest', ['bodytest'], el.frame, BoxStyle{}, TextStyle{size: 14})
	native_update_dropdown(popup, shorter, false)
	assert macos.msg_i64(popup, 'numberOfItems') == 1
	assert native_dropdown_text(popup) == 'bodytest'
}
