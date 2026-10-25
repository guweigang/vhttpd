module main

import host
import ui2

fn (app &Workshop) shared_form() host.SharedRelay {
	return host.SharedRelay{ id: app.shared_id, relay_id: app.shared_remote_id, name: app.shared_name.trim_space(), url: app.shared_url.trim_space(), token: app.shared_token }
}

fn (app &Workshop) shared_saved() bool {
	return app.shared_relays.any(it == app.shared_form())
}

fn (mut app Workshop) handle_shared_relay_event(event string) bool {
	if event == 'shared_relays' {
		app.show_shared_relays = true
		return true
	}
	if event == 'shared_close' {
		app.show_shared_relays = false
		return true
	}
	if !event.starts_with('shared_') { return false }
	if app.shared_testing { return true }
	match event {
		'shared_new' {
			app.shared_id = host.new_shared_relay_id() or {
				app.shared_message = '无法创建连接编号。'
				return true
			}
			app.shared_remote_id = 'hub'
			app.shared_name = ''
			app.shared_url = ''
			app.shared_token = ''
			app.shared_message = '新建连接；Token 仅保存在本机权限保护的文件中。'
		}
		'shared_name' {
			app.shared_name = ui2.text(event)
			app.shared_message = '连接已修改，保存或测试后再使用。'
		}
		'shared_url' {
			app.shared_url = ui2.text(event)
			app.shared_message = '地址已修改，原测试结果不再有效。'
		}
		'shared_remote_id' {
			app.shared_remote_id = ui2.text(event)
			app.shared_message = 'Relay ID 已修改，请重新测试。'
		}
		'shared_token' {
			app.shared_token = ui2.text(event)
			app.shared_message = '认证已修改，原测试结果不再有效。'
		}
		'shared_save' {
			r := app.shared_form()
			r.validate() or {
				app.shared_message = err.msg()
				return true
			}
			mut items := app.shared_relays.filter(it.id != r.id)
			items << r
			host.save_shared_relays(items) or {
				app.shared_message = '保存失败，连接库未更新。'
				return true
			}
			app.shared_relays = items
			app.shared_message = '连接已保存；已有项目保持原配置。可点击测试连接。'
		}
		'shared_delete' {
			if !ui2.confirm('删除共享连接', '仅从连接库删除；不会修改或删除任何项目中的 Relay 配置。') {
				return true
			}
			items := app.shared_relays.filter(it.id != app.shared_id)
			host.save_shared_relays(items) or {
				app.shared_message = '删除失败，连接库未更新。'
				return true
			}
			app.shared_relays = items
			app.shared_id = ''
			app.shared_remote_id = 'hub'
			app.shared_name = ''
			app.shared_url = ''
			app.shared_token = ''
			app.shared_message = '共享连接已删除，项目配置未修改。'
		}
		'shared_test' {
			r := app.shared_form()
			r.validate() or {
				app.shared_message = err.msg()
				return true
			}
			app.shared_testing = true
			app.shared_message = '正在测试网络、WebSocket 和 Relay 认证；不会使用项目 Node ID 或启用业务 Pipeline…'
			spawn test_shared_connection(r, app.shared_results)
		}
		'shared_use' {
			if app.projects.len == 0 || app.snapshot.phase != .running || !app.shared_saved() {
				app.shared_message = '请保存连接并启动所选项目。'
				return true
			}
			next := app.sequence + 1
			select {
				app.worker.commands <- host.Command{ action: .use_shared_relay, sequence: next, shared_relay: app.shared_form() } {
					app.sequence = next
					app.shared_use_pending = true
					app.shared_message = '正在打开项目的独立草稿；请在 Admin UI 完成绑定、校验与发布。'
				}
				else {
					app.shared_message = '工作台正在处理操作，请稍后重试。'
				}
			}
		}
		else {
			if event.starts_with('shared_pick_') {
				id := event.all_after('shared_pick_')
				for r in app.shared_relays {
					if r.id == id {
						app.shared_id = r.id
						app.shared_remote_id = r.relay_id
						app.shared_name = r.name
						app.shared_url = r.url
						app.shared_token = r.token
						app.shared_message = '尚未测试此连接；连接库状态与项目运行状态分开显示。'
						break
					}
				}
			}
		}
	}
	return true
}

fn test_shared_connection(r host.SharedRelay, results chan host.RelayProbeResult) {
	results <- host.probe_shared_relay(r)
}

fn shared_relays_view(app &Workshop, width f64) []ui2.Element {
	list_width := if width >= 620 { 174.0 } else { 144.0 }
	x := list_width + 24
	mut selector := [button('shared_new', '+ 新建连接', 10, 10, list_width - 20, false, !app.shared_testing)]
	mut connections := []ui2.Element{}
	for i, relay in app.shared_relays {
		connections << sidebar_button('shared_pick_' + relay.id, relay.name, ui2.rect(0, f64(i * 42), list_width - 20, 36), false, app.shared_id == relay.id, !app.shared_testing, .left)
	}
	selector << ui2.scroll('shared_list', ui2.rect(10, 58, list_width - 20, 340), workbench_sidebar, connections)
	body := shared_relay_detail(app, width - x)
	return [label('shared_title', '共享 Relay', 0, 26, width - 120, 24, workbench_ink),
		label('shared_intro', '维护跨项目复用的连接；项目绑定与配置发布在 Admin UI 完成。', 0, 62, width, 12, workbench_muted),
		button('shared_close', '返回项目', width - 100, 26, 100, false, true),
		ui2.view('shared_selector', ui2.rect(0, 106, list_width, 414), ui2.BoxStyle{bg: workbench_sidebar, radius: 8}, selector),
		ui2.view('shared_detail', ui2.rect(x, 106, width - x, elements_height(body)), ui2.BoxStyle{transparent: true}, body)]
}

fn shared_relay_detail(app &Workshop, width f64) []ui2.Element {
	if app.shared_id == '' {
		return [label('shared_empty', '先创建一个共享连接', 0, 18, width, 20, workbench_ink),
			ui2.label('shared_empty_help', '填写远端 Hub 地址，测试通过后供项目选择使用。连接测试与项目运行状态分别显示。', ui2.rect(0, 60, width, 90), ui2.TextStyle{size: 13, color: workbench_muted, lines: 4})]
	}
	mut rows := [label('shared_detail_title', '连接设置', 0, 0, width, 20, workbench_ink),
		label('shared_name_label', '显示名称', 0, 44, width, 11, workbench_muted),
		input('shared_name', app.shared_name, '例如：开发环境 Hub', 0, 65, width, !app.shared_testing),
		label('shared_url_label', 'Hub 地址（ws:// 或 wss://）', 0, 118, width, 11, workbench_muted),
		input('shared_url', app.shared_url, 'wss://example.com/vhttpd/relay', 0, 139, width, !app.shared_testing),
		label('shared_remote_label', '远端 Relay ID', 0, 192, width, 11, workbench_muted),
		input('shared_remote_id', app.shared_remote_id, '与 Hub 配置保持一致', 0, 213, width, !app.shared_testing),
		label('shared_token_label', '认证 Token（可选）', 0, 266, width, 11, workbench_muted),
		ui2.Element{...input('shared_token', app.shared_token, '不放入 URL', 0, 287, width, !app.shared_testing), secure: true},
		button('shared_save', '保存连接', 0, 345, 100, !app.shared_saved(), !app.shared_testing),
		button('shared_test', if app.shared_testing { '测试中…' } else { '测试连接' }, 112, 345, 100, false, !app.shared_testing),
		button('shared_delete', '移除…', width - 78, 345, 78, false, !app.shared_testing && app.shared_saved()),
		state_notice('shared_notice', if app.shared_testing { '正在测试连接' } else { '连接状态' }, if app.shared_message == '' { '保存后测试连接，再选择用于项目。' } else { app.shared_message }, ui2.rect(0, 404, width, 100), 'info')]
	project := if app.projects.len > 0 { app.projects[app.selected].name } else { '请先创建或选择本地项目' }
	rows << label('shared_project_label', '用于项目 · ' + project, 0, 528, width, 13, workbench_ink)
	rows << button('shared_use', '在项目中使用 ↗', 0, 562, width, app.shared_saved(), !app.shared_testing && app.shared_saved() && app.projects.len > 0 && app.snapshot.phase == .running)
	rows << ui2.label('shared_use_hint', '先保存连接并启动项目。此操作仅生成草稿，仍需在 Admin UI 校验和发布。', ui2.rect(0, 612, width, 56), ui2.TextStyle{size: 11, color: workbench_muted, lines: 3})
	return rows
}
