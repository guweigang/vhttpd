module main

import host
import os
import ui2

struct RuntimeResult {
	info        host.RuntimeInfo
	path        string
	error       string
	select_path bool
	downloaded  bool
}

fn runtime_inspect_task(path string, executable string, select_path bool, results chan RuntimeResult, job host.RuntimeJob) {
	info := host.inspect_runtime(path, executable, job)
	if select_path && info.ready {
		host.save_runtime_selection(path) or {
			results <- RuntimeResult{ error: err.msg() }
			return
		}
	}
	results <- RuntimeResult{ info: info, path: path, select_path: select_path }
}

fn runtime_download_task(executable string, results chan RuntimeResult, job host.RuntimeJob) {
	path := host.download_runtime(job) or {
		results <- RuntimeResult{ error: err.msg() }
		return
	}
	results <- RuntimeResult{ info: host.inspect_runtime(path, executable, host.RuntimeJob{}), path: path, select_path: true, downloaded: true }
}

fn (mut app Workshop) inspect_binary(path string, select_path bool) {
	if app.runtime_busy { return }
	app.runtime_busy = true
	app.runtime_job = host.RuntimeJob{}
	app.runtime_message = '正在读取运行程序版本…'
	spawn runtime_inspect_task(path, os.executable(), select_path, app.runtime_results, app.runtime_job)
}

fn (mut app Workshop) poll_runtime() {
	for _ in 0 .. 16 {
		select {
			progress := <-app.runtime_job.progress {
				app.runtime_message = progress
			}
			else {
				break
			}
		}
	}
	select {
		result := <-app.runtime_results {
			app.runtime_busy = false
			if result.error != '' {
				app.runtime_message = result.error
				app.runtime_error = true
				return
			}
			if !result.select_path || result.info.ready {
				app.binary = result.path
				app.runtime_info = result.info
				app.runtime_checked = true
			}
			app.runtime_error = !result.info.ready
			app.runtime_message = if result.downloaded {
				'运行包已安装并切换，可直接启动项目。'
			} else {
				result.info.message
			}
			if app.runtime_resume_start && result.info.ready {
				app.runtime_resume_start = false
				app.show_runtime = false
				app.launch()
			}
		}
		else {
		}
	}
}

fn (mut app Workshop) handle_runtime_event(event string) bool {
	if event == 'runtime' || event == 'runtime_download' {
		app.show_runtime = true
		app.show_shared_relays = false
		if event == 'runtime' { return true }
		if app.runtime_busy || app.snapshot.pid != 0 || app.snapshot.phase in [
			.starting,
			.stopping,
		] {
			return true
		}
		app.runtime_busy = true
		app.runtime_error = false
		app.runtime_job = host.RuntimeJob{}
		app.runtime_message = '正在查找官方运行包…'
		spawn runtime_download_task(os.executable(), app.runtime_results, app.runtime_job)
		return true
	}
	if event == 'runtime_close' {
		app.show_runtime = false
		app.runtime_resume_start = false
		return true
	}
	if event == 'runtime_cancel' {
		if app.runtime_busy {
			app.runtime_resume_start = false
			select {
				app.runtime_job.cancel <- true {
				}
				else {
				}
			}
			app.runtime_message = '正在取消，当前运行包保持不变…'
		}
		return true
	}
	if event == 'runtime_refresh' {
		app.inspect_binary(app.binary, false)
		return true
	}
	if event == 'runtime_bundled' {
		if !app.runtime_busy && app.snapshot.pid == 0 {
			bundled := os.join_path(os.dir(os.executable()), '..', 'Resources', 'runtime', 'vhttpd')
			app.inspect_binary(os.real_path(bundled), true)
		}
		return true
	}
	return false
}

fn runtime_local_view(app &Workshop, width f64) []ui2.Element {
	can_switch := !app.runtime_busy && app.snapshot.pid == 0 && app.snapshot.phase !in [.starting, .stopping]
	mut rows := [label('runtime_title', '本机 Mac', 0, 0, width, 20, workbench_ink),
		label('runtime_version', if app.runtime_info.ready { 'vhttpd ' + app.runtime_info.version } else if app.runtime_checked { '运行包不可用' } else { '正在识别版本…' }, 0, 36, width, 16, workbench_ink),
		label('runtime_source', '来源：' + app.runtime_info.source, 0, 68, width, 12, workbench_muted),
		ui2.label('runtime_path', app.binary, ui2.rect(0, 94, width, 52), ui2.TextStyle{size: 11, color: workbench_muted, lines: 3}),
		state_notice('runtime_notice', if app.runtime_busy { '正在准备运行环境' } else if app.runtime_error { '运行环境未就绪' } else if app.runtime_info.ready { '运行环境已就绪' } else { '准备运行包' }, app.runtime_message, ui2.rect(0, 158, width, 96), if app.runtime_error { 'warning' } else if app.runtime_info.ready && !app.runtime_busy { 'good' } else { 'info' }),
		button('runtime_download', if app.runtime_busy { '正在处理…' } else { '下载官方运行包' }, 0, 276, width, !app.runtime_info.ready, can_switch),
		button('binary', '选择本地 vhttpd…', 0, 322, width, false, can_switch),
		button('runtime_refresh', '刷新版本', 0, 378, (width - 12) / 2, false, !app.runtime_busy),
		button('runtime_bundled', '使用内置版本', (width + 12) / 2, 378, (width - 12) / 2, false, can_switch),
		ui2.label('runtime_release_hint', '官方完整包包含运行程序与依赖，无需安装开发环境。仅在本机项目停止时切换。', ui2.rect(0, 432, width, 54), ui2.TextStyle{size: 11, color: workbench_muted, lines: 3})]
	if app.runtime_busy { rows << button('runtime_cancel', '取消操作', 0, 500, 110, false, true) }
	if app.runtime_resume_start { rows << ui2.label('runtime_resume', '项目已保留。运行包就绪后自动继续启动。', ui2.rect(0, 550, width, 48), ui2.TextStyle{size: 12, color: workbench_ink, lines: 2}) }
	return rows
}
