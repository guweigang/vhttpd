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
	mut rows := [
		label('shared_title', '远端 Relay 连接库', 0, 30, width, 25, workbench_ink),
		label('shared_intro', '跨项目复用连接；测试结果与项目实际连接状态分别显示。', 0, 76, width, 12, workbench_muted),
		button('shared_close', '返回工作台', 0, 108, 112, false, true),
		button('shared_new', '新建连接', 125, 108, 108, true, !app.shared_testing),
	]
	mut connections := []ui2.Element{}
	for i, r in app.shared_relays {
		connections << sidebar_button('shared_pick_' + r.id, r.name + ' · ' + r.url, ui2.rect(0, f64(i * 42), width - 12, 36), false, app.shared_id == r.id, !app.shared_testing, .left)
	}
	if connections.len == 0 {
		connections << label('shared_empty', '还没有共享连接。点击“新建连接”，填写远端 Hub 的 WebSocket 地址。', 0, 0, width - 12, 12, workbench_muted)
	}
	rows << ui2.scroll('shared_list', ui2.rect(0, 158, width, 135), workbench_sidebar, connections)
	if app.shared_id != '' {
		rows << label('shared_name_label', '连接名称', 0, 312, width, 12, workbench_ink)
		rows << input('shared_name', app.shared_name, '例如：开发环境 Hub', 0, 337, width, !app.shared_testing)
		rows << label('shared_url_label', 'Hub 地址（ws:// 或 wss://）', 0, 390, width, 12, workbench_ink)
		rows << input('shared_url', app.shared_url, 'wss://example.com/vhttpd/relay', 0, 415, width, !app.shared_testing)
		rows << label('shared_remote_label', '远端 Relay ID（与 Hub 配置一致）', 0, 468, width, 12, workbench_ink)
		rows << input('shared_remote_id', app.shared_remote_id, 'hub', 0, 493, width, !app.shared_testing)
		rows << label('shared_token_label', 'Token（不放入 URL）', 0, 546, width, 12, workbench_ink)
		rows << ui2.Element{ ...input('shared_token', app.shared_token, '远端认证 Token，可留空', 0, 571, width, !app.shared_testing), secure: true }
		rows << button('shared_save', '保存连接', 0, 629, 100, true, !app.shared_testing)
		rows << button('shared_test', if app.shared_testing {
			'测试中…'
		} else {
			'测试连接'
		}, 112, 629, 100, false, !app.shared_testing)
		rows << button('shared_delete', '删除', 224, 629, 75, false, !app.shared_testing && app.shared_saved())
		project := if app.projects.len > 0 {
			app.projects[app.selected].name
		} else {
			'请先创建或选择项目'
		}
		rows << label('shared_project_label', '选入项目：' + project, 0, 688, width, 13, workbench_ink)
		rows << button('shared_use', '在项目中使用 ↗', 0, 720, 180, true, !app.shared_testing && app.shared_saved() && app.projects.len > 0 && app.snapshot.phase == .running)
		rows << label('shared_use_hint', '先保存连接并启动项目。仅生成草稿；来源、Pipeline 绑定与发布在 Admin UI 完成。', 0, 766, width, 11, workbench_muted)
	}
	rows << state_notice('shared_notice', if app.shared_testing {
		'正在测试'
	} else {
		'连接库'
	}, app.shared_message, ui2.rect(0, if app.shared_id != '' { 811.0 } else { 330.0 }, width, 100), 'info')
	return rows
}
