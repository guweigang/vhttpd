module main

import host
import ui2

// Validate actual rendered trees: duplicate IDs cause the native renderer to
// keep the old page, even though callbacks and runtime operations still work.
fn test_takeover_and_relay_logs_have_valid_trees_in_both_states() ! {
	for active in [false,true] {
		app := Workshop{takeover_relay:'edge',snapshot:host.Snapshot{
			phase:.running,takeover_relay_id:'edge',
			takeover_status:host.TakeoverStatus{known:true,active:active}}}
		for width in [560.0,760.0] {
			ui2.validate_element_tree(ui2.screen(workbench_paper,takeover_view(&app,width)))!
			ui2.validate_element_tree(ui2.screen(workbench_paper,relay_monitor_view(&app,width)))!
		}
	}
}

fn test_takeover_entry_remains_available_with_stopped_local_environment() ! {
	mut app := Workshop{projects:[host.Project{name:'bodytest',config_path:'/fixture/vhttpd.toml'}],workspace_page:.applications}
	for width in [488.0,708.0] {
		root := ui2.screen(workbench_paper,runtime_workspace_view(mut app,width,740))
		ui2.validate_element_tree(root)!
		assert menu_button_enabled(root,'takeover_open')
		form := ui2.screen(workbench_paper,takeover_view(&app,width))
		ui2.validate_element_tree(form)!
		assert menu_button_enabled(form,'takeover_runtime_start')
		assert !menu_button_enabled(form,'takeover_start')
		assert !menu_button_enabled(form,'takeover_status')
	}
	assert app.handle_takeover_event('takeover_open')
	assert app.show_takeover && app.sequence == 0
}
