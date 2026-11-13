module main

import ui2

fn menu_text_has_selection() bool { return ui2.workbench_text_has_selection() }
fn menu_text_edit(action string) { ui2.workbench_text_edit(action) }
fn configure_platform_menus() {}
fn menu_window_action(_action string) {}
