module main

import host
import os
import ui2

struct RuntimeCatalogResult {
	choices []host.RuntimeDownload
	platform string
	target string
	error string
}

fn (app &Workshop) download_platform() string {
	if app.runtime_server_id == '' { return 'macos-arm64' }
	if app.server_snapshot.connected && app.server_snapshot.server_id == app.runtime_server_id { return app.server_snapshot.platform }
	return ''
}

fn runtime_catalog_task(platform string, target string, channel string, specified string, job host.RuntimeJob, results chan RuntimeCatalogResult) {
	choices := host.runtime_catalog(platform, channel, specified, job) or {
		results <- RuntimeCatalogResult{platform: platform, target: target, error: err.msg()}
		return
	}
	results <- RuntimeCatalogResult{platform: platform, target: target, choices: choices}
}

fn (mut app Workshop) load_runtime_catalog() {
	if app.runtime_catalog_busy { return }
	platform := app.download_platform()
	if platform == '' { app.runtime_catalog_error = '请先连接目标服务器。'; return }
	app.runtime_catalog_busy = true
	app.runtime_catalog_error = ''
	app.runtime_selected_tag = ''
	app.runtime_downloads = []host.RuntimeDownload{}
	app.runtime_catalog_job = host.RuntimeJob{}
	spawn runtime_catalog_task(platform, app.runtime_server_id, app.runtime_catalog_channel, app.runtime_catalog_ref, app.runtime_catalog_job, app.runtime_catalog_results)
}

fn (mut app Workshop) open_runtime_downloads() {
	app.show_runtime_downloads = true
	app.runtime_selected_tag = ''
	app.load_runtime_catalog()
}

fn (mut app Workshop) poll_runtime_catalog() {
	select {
		result := <-app.runtime_catalog_results {
			app.runtime_catalog_busy = false
			if result.target != app.runtime_server_id || result.platform != app.download_platform() {
				if app.show_runtime_downloads { app.load_runtime_catalog() }
				return
			}
			app.runtime_downloads = result.choices
			app.runtime_catalog_error = result.error
		}
		else {}
	}
}

fn (app &Workshop) can_install_selected_runtime() bool {
	if app.runtime_catalog_busy || app.runtime_selected_tag == '' { return false }
	if !app.runtime_downloads.any(it.tag == app.runtime_selected_tag && it.platform == app.download_platform()) { return false }
	if app.runtime_server_id == '' { return !app.runtime_busy && app.snapshot.pid == 0 && app.snapshot.phase !in [.starting, .stopping] }
	return app.server_snapshot.connected && !app.server_busy && !app.server_snapshot.busy && app.remote_servers.any(it.id == app.runtime_server_id && it == app.server_snapshot.server)
}

fn (mut app Workshop) handle_runtime_catalog_event(event string) bool {
	if event == 'runtime_ref' { app.runtime_catalog_ref = ui2.text(event); app.runtime_selected_tag = ''; return true }
	if event == 'runtime_catalog_close' { app.show_runtime_downloads = false; return true }
	if event == 'runtime_catalog_cancel' { select { app.runtime_catalog_job.cancel <- true {} else {} }; return true }
	if event == 'runtime_catalog_load' {
		if app.runtime_catalog_ref.trim_space() != '' { app.runtime_catalog_channel = 'all' }
		app.load_runtime_catalog()
		return true
	}
	if event.starts_with('runtime_channel_') {
		if app.runtime_catalog_busy { return true }
		app.runtime_catalog_channel = event.all_after('runtime_channel_')
		app.runtime_catalog_ref = ''
		app.load_runtime_catalog()
		return true
	}
	if event.starts_with('runtime_release_') {
		if app.runtime_catalog_busy { return true }
		index := event.all_after('runtime_release_').int()
		if index >= 0 && index < app.runtime_downloads.len { app.runtime_selected_tag = app.runtime_downloads[index].tag }
		return true
	}
	if event == 'runtime_install_selected' {
		if !app.can_install_selected_runtime() { return true }
		app.show_runtime_downloads = false
		if app.runtime_server_id != '' { app.server_command(.install, ''); return true }
		app.runtime_busy = true
		app.runtime_error = false
		app.runtime_job = host.RuntimeJob{}
		app.runtime_message = '正在下载 ' + app.runtime_selected_tag + '…'
		spawn runtime_download_task(app.runtime_selected_tag, os.executable(), app.runtime_results, app.runtime_job)
		return true
	}
	return false
}

fn runtime_downloads_view(app &Workshop, width f64) []ui2.Element {
	busy := app.runtime_catalog_busy
	mut rows := [button('runtime_catalog_close', '← 返回运行环境', 0, 0, 150, false, true),
		label('runtime_download_heading', '选择运行包版本', 0, 52, width, 20, workbench_ink),
		label('runtime_download_platform', app.download_platform() + ' · 公开下载，无需 GitHub 登录', 0, 84, width, 11, workbench_muted),
		ui2.Element{...input('runtime_ref', app.runtime_catalog_ref, '版本号或官方 Release 链接', 0, 114, width - 90, !busy), submit_id: 'runtime_catalog_load'},
		button(if busy { 'runtime_catalog_cancel' } else { 'runtime_catalog_load' }, if busy { '取消' } else { '查询' }, width - 78, 114, 78, false, true)]
	third := (width - 16) / 3
	for i, channel in ['all', 'stable', 'development'] {
		rows << choice_button('runtime_channel_${channel}', ['全部', '稳定版', '开发版'][i], f64(i) * (third + 8), 164, third, app.runtime_catalog_channel == channel, !busy)
	}
	mut choices := []ui2.Element{}
	for i, choice in app.runtime_downloads {
		mut row := [label('runtime_release_name_${i}', choice.tag, 10, 3, width - 40, 12, workbench_ink),
			label('runtime_release_meta_${i}', if choice.channel == 'stable' { '稳定版' } else { '开发版 · 预发布' } + ' · ' + choice.published_at.all_before('T'), 10, 27, width - 40, 10, workbench_muted)]
		row << ui2.Element{...ui2.button('runtime_release_${i}', '', ui2.rect(0, 0, width - 12, 52), ui2.BoxStyle{transparent: true}, ui2.TextStyle{}), enabled: !busy, accessibility_label: choice.tag + ' · ' + choice.channel}
		focused := ui2.focused_id() == 'runtime_release_${i}'
		choices << ui2.view('runtime_release_row_${i}', ui2.rect(0, f64(i * 58), width - 12, 52), ui2.BoxStyle{bg: if app.runtime_selected_tag == choice.tag { workbench_soft_accent } else { workbench_sidebar }, radius: 6, border_color: workbench_accent, border_left: if focused { 2.0 } else { 0.0 }, border_right: if focused { 2.0 } else { 0.0 }, border_top: if focused { 2.0 } else { 0.0 }, border_bottom: if focused { 2.0 } else { 0.0 }}, row)
	}
	rows << ui2.scroll('runtime_release_list', ui2.rect(0, 210, width, 180), workbench_sidebar, choices)
	rows << state_notice('runtime_catalog_notice', if busy { '正在读取版本列表' } else if app.runtime_catalog_error != '' { '版本查询未完成' } else if choices.len == 0 { '暂无可安装版本' } else { '选择后再安装' }, if app.runtime_catalog_error != '' { app.runtime_catalog_error } else if choices.len == 0 && !busy { '仅列出包含完整运行包和校验文件的公开版本。可指定旧版本，或选择本地包。' } else if app.runtime_selected_tag != '' { app.runtime_selected_tag } else { '最近 30 个公开版本，按目标平台筛选。开发版来自通过 CI 的预发布。' }, ui2.rect(0, 410, width, 92), if app.runtime_catalog_error != '' { 'warning' } else { 'info' })
	rows << button('runtime_install_selected', '安装所选版本', 0, 524, width, true, app.can_install_selected_runtime())
	rows << ui2.label('runtime_download_hint', '安装前校验 SHA256、完整性和平台兼容性。选择不会替换当前运行包。', ui2.rect(0, 574, width, 52), ui2.TextStyle{size: 11, color: workbench_muted, lines: 3})
	return rows
}
