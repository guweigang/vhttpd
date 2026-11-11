module main

import os
import ui2

fn test_workbench_appearance_preferences() ! {
	directory := os.join_path(os.temp_dir(), 'vhttpd-appearance-test-' + os.getpid().str())
	defer { os.rmdir_all(directory) or {} }
	path := os.join_path(directory, 'appearance')
	assert load_appearance(path) == .system
	for mode in [ui2.ComponentThemeMode.dark, .light, .system] {
		save_appearance(path, mode)!
		assert load_appearance(path) == mode
	}
	os.write_file(path, 'invalid')!
	assert load_appearance(path) == .system
}

fn test_workbench_appearance_updates_controls_and_menu() ! {
	previous_mode := workbench_appearance_mode
	previous_system := workbench_system_appearance
	defer {
		workbench_appearance_mode = previous_mode
		workbench_system_appearance = previous_system
		apply_workbench_appearance()
	}
	app := Workshop{}
	for mode in [ui2.ComponentThemeMode.light, .dark, .system] {
		workbench_appearance_mode = mode
		workbench_system_appearance = .dark
		apply_workbench_appearance()
		dark := mode != .light
		if dark {
			assert workbench_colors.paper == 0x202020
			assert workbench_colors.sidebar == 0x282828
			assert workbench_component_theme.background == workbench_colors.paper
			assert workbench_component_theme.muted == workbench_colors.disabled_background
			assert workbench_component_theme.primary == ui2.component_theme(true).primary
		} else {
			assert workbench_component_theme == ui2.component_theme(false)
			assert workbench_colors == WorkbenchColors{}
		}
		assert app.update_settings_config().theme == workbench_component_theme
		primary := button('primary', 'Primary', 0, 0, 120, true, true)
		sidebar_primary := sidebar_button('sidebar_primary', 'Primary', ui2.rect(0, 0, 120, 34), true, false, true, .center)
		for element in [primary, sidebar_primary] {
			assert element.box.bg == 0x2563eb
			assert element.children[0].text_style.color == 0xffffff
		}
		assert primary.box.border_color == primary.box.bg
		assert button('secondary', 'Secondary', 0, 0, 120, false, true).box.border_color == workbench_colors.line
		disabled := button('disabled', 'Disabled', 0, 0, 120, true, false)
		assert disabled.box.border_color == workbench_colors.line
		assert disabled.box.bg != disabled.children[0].text_style.color

		menus := app.workbench_menus(ui2.screen(workbench_colors.paper, []))
		for choice in [ui2.ComponentThemeMode.light, .dark, .system] {
			item := menu_find(menus[3].items, 'menu:appearance:' + choice.str()) or {
				return error('missing Appearance menu item: ' + choice.str())
			}
			assert item.checked == (mode == choice)
		}
	}
	workbench_system_appearance = .unknown
	apply_workbench_appearance()
	assert workbench_colors == WorkbenchColors{}
}
