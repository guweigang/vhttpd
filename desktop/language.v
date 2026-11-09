module main

import host
import l10n
import os
import ui2

__global workbench_language = 'zh-CN'
__global workbench_language_preference = 'auto'
__global workbench_system_language = ''
__global workbench_language_file = ''

fn initialize_language() {
	workbench_system_language = system_language()
	workbench_language_file = os.join_path(host.workbench_data_dir(), 'language.json')
	pref := l10n.load_preferences(workbench_language_file) or { l10n.Preferences{} }
	workbench_language_preference = pref.language
	workbench_language = l10n.effective_language(pref.language, workbench_system_language)
}

fn ui_text(text string) string { return l10n.text(workbench_language, text) }

fn ui_text_in(context string, text string) string {return l10n.text_in(workbench_language,context,text)}

fn ui_alert(title string, text string) { ui2.alert(ui_text(title), ui_text(text)) }

fn ui_confirm(title string, text string) bool { return ui2.confirm(ui_text(title), ui_text(text)) }

fn choose_language(preference string) {
	if !l10n.valid_preference(preference) { return }
	l10n.save_preferences(workbench_language_file, preference) or {
		ui_alert('无法保存语言设置', err.msg())
		return
	}
	workbench_language_preference = preference
	workbench_language = l10n.effective_language(preference, workbench_system_language)
	set_workbench_window_title(ui_text('vhttpd · 本地工作台'))
	if ui2.tray_visible() { set_workbench_tray(ui2.tray().icon) }
	ui2.refresh()
}

// Names and endpoints are user data, even when they happen to equal UI wording.
fn untranslated_ui_text(id string) bool {
	return id.ends_with('_name') || id in ['workspace_title', 'workspace_application_name',
		'remote_existing_name', 'remote_connected_name', 'remote_config_source',
		'remote_existing_source', 'server_identity_path', 'remote_identity_path', 'shared_detail_title',
		'server_detail_title']
		|| id.starts_with('server_select_')
		|| (id.starts_with('runtime_target_') && id !in ['runtime_target_label', 'runtime_target_', 'runtime_target__caption'])
}

fn localize_element(element ui2.Element) ui2.Element {
	mut children := []ui2.Element{cap: element.children.len}
	for child in element.children { children << localize_element(child) }
	preserve := element.kind !in [.text_field, .text_area] && untranslated_ui_text(element.id)
	// Editable values, original logs/diffs, and environment dropdown entries
	// must remain byte-for-byte unchanged. Placeholders and accessible labels
	// describe controls and can be localized independently of their values.
	translate_value := element.kind !in [.text_field, .text_area, .dropdown] && !preserve
	translated := if translate_value { ui_text(element.text) } else { element.text }
	return ui2.Element{
		...element
		children:            children
		text:                translated
		text_style:          element.text_style
		placeholder:         ui_text(element.placeholder)
		accessibility_label: if preserve {
			element.accessibility_label
		} else {
			ui_text(element.accessibility_label)
		}
	}
}

fn localize_menu_item(item ui2.MenuItem) ui2.MenuItem {
	mut children := []ui2.MenuItem{}
	for child in item.items { children << localize_menu_item(child) }
	data := item.id.starts_with('menu:project_') || item.id.starts_with('menu:remote_select_')
	// Location labels combine a UI prefix with a user-supplied server name.
	// Translate that prefix only, even when the name equals a UI message.
	location := item.id.starts_with('menu:environment:') && item.id != 'menu:environment:'
	title := if location && item.title.starts_with('远端 · ') {
		ui_text('远端 · ') + item.title['远端 · '.len..]
	} else if data || location {
		item.title
	} else {
		ui_text(item.title)
	}
	return ui2.MenuItem{ ...item, title: title, items: children }
}

fn localize_menus(menus []ui2.Menu) []ui2.Menu {
	mut result := []ui2.Menu{}
	for menu in menus {
		mut items := []ui2.MenuItem{}
		for item in menu.items { items << localize_menu_item(item) }
		result << ui2.Menu{ ...menu, title: ui_text(menu.title), items: items }
	}
	return result
}
