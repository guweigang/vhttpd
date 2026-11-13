module main

import ui2

__global menu_probe_form_open = false

fn probe_menus() {
	ui2.set_menu_bar([ui2.Menu{
		title: 'Project'
		items: [ui2.MenuItem{id: 'new', title: 'New', enabled: !menu_probe_form_open, shortcut: 'cmd+n'}]
	}])
}

fn probe_screen() ui2.Element {
	return ui2.screen(0xffffff, [
		ui2.label('state', if menu_probe_form_open { 'FORM OPEN' } else { 'HOME' },
			ui2.rect(20, 20, 300, 35), ui2.TextStyle{size: 18}),
		ui2.text_field('fixture', 'fixture', '', ui2.rect(20, 70, 400, 35),
			ui2.BoxStyle{}, ui2.TextStyle{size: 16}, 0),
	])
}

fn probe_command(id string) {
	if id != 'new' { return }
	menu_probe_form_open = true
	probe_menus()
	ui2.refresh()
	ui2.focus('fixture')
}

fn probe_key(key string) {
	if key == 'cmd+n' { probe_command('new') }
}

fn probe_physical_key(event ui2.KeyEvent) {
	if event.code != .escape { return }
	// This is the workbench's existing cancel pattern: the typed callback is
	// also invoked from UI2Window.performKeyEquivalent, before native handling.
	menu_probe_form_open = false
	probe_menus()
	ui2.consume_key()
	ui2.refresh()
}

fn main() {
	probe_menus()
	ui2.on_key(probe_key)
	ui2.on_key_event(probe_physical_key)
	ui2.run_window('ui2 Menu Escape Probe', 500, 260, probe_screen, probe_command)
}
