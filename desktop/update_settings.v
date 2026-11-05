module main

import host
import ui2

struct DesktopUpdateResult {
	update host.DesktopUpdate
	error  string
}

fn check_desktop_update_task(job host.RuntimeJob, results chan DesktopUpdateResult) {
	update := host.check_desktop_update(desktop_version, job) or {
		results <- DesktopUpdateResult{error: err.msg()}
		return
	}
	results <- DesktopUpdateResult{update: update}
}

fn (mut app Workshop) start_desktop_update_check() {
	if app.desktop_update_busy { return }
	app.desktop_update_busy = true
	app.desktop_update_result = DesktopUpdateResult{}
	app.desktop_update_checked = false
	app.desktop_update_job = host.RuntimeJob{}
	spawn check_desktop_update_task(app.desktop_update_job, app.desktop_update_results)
}

fn (mut app Workshop) poll_desktop_update() {
	if !app.desktop_update_busy { return }
	select {
		result := <-app.desktop_update_results {
			app.desktop_update_result = result
			app.desktop_update_busy = false
			app.desktop_update_checked = true
		}
		else {}
	}
}

fn (app &Workshop) update_settings_config() ui2.SettingsConfig {
	bounds := workbench_bounds()
	width := if bounds.width > 760 { bounds.width } else { 760.0 }
	height := if bounds.height > 660 { bounds.height } else { 660.0 }
	result := app.desktop_update_result
	status := if app.desktop_update_busy {
		'正在检查更新…'
	} else if result.error != '' {
		result.error
	} else if result.update.url != '' {
		'发现新版 Desktop' + ' ' + result.update.version
	} else if app.desktop_update_checked {
		'当前没有可用的新版 Desktop。'
	} else {
		'查询 GitHub 上适用于本机的稳定版。'
	}
	mut rows := [ui2.SettingItem{
		key: 'general.check_now'
		title: '软件更新'
		description: status
		kind: .button
		button_text: '检查更新'
		disabled: app.desktop_update_busy
	}]
	if result.update.url != '' {
		rows << ui2.SettingItem{
			key: 'general.open_release'
			title: '下载新版'
			description: '在浏览器中打开此版本的 GitHub 发布页。'
			kind: .button
			button_text: '前往 GitHub'
		}
	}
	return ui2.SettingsConfig{
		id: 'desktop_update_settings'
		frame: ui2.rect(0, 58, width, height - 58)
		state: app.desktop_update_settings
		nav_width: 0
		theme: ui2.component_theme(false)
		accessibility_label: '软件更新'
		group_variant: .outline
		pages: [ui2.SettingPage{
			id: 'updates'
			title: '软件更新'
			description: '当前版本' + ' · Desktop ' + desktop_version
			groups: [ui2.SettingGroup{items: rows}]
		}]
	}
}

fn (mut app Workshop) handle_desktop_update_event(event string) bool {
	if !app.desktop_update_open { return false }
	if event == 'desktop_update_back' {
		app.desktop_update_open = false
		ui2.refresh()
		return true
	}
	if step := ui2.settings_update(app.update_settings_config(), event, ui2.SettingsInput{text: ui2.text}) {
		app.desktop_update_settings = step.state
		match step.action {
			'general.check_now' { app.start_desktop_update_check() }
			'general.open_release' {
				if app.desktop_update_result.update.url != '' {
					host.open_local(app.desktop_update_result.update.url) or {
						ui2.alert('无法打开 GitHub', err.msg())
					}
				}
			}
			else {}
		}
		ui2.refresh()
		if step.scroll { ui2.scroll_to_offset(step.scroll_id, step.scroll_to) }
		if step.focus != '' { ui2.focus(step.focus) }
		return true
	}
	return false
}
