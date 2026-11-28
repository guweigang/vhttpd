module main

import crypto.sha256
import json2 as json
import host
import time

fn (app &Workshop) catalog_ready() bool {
	return app.environment_id == '' || (app.server_snapshot.connected && app.server_snapshot.server_id == app.environment_id && app.server_snapshot.relay_catalog.loaded)
}

fn (app &Workshop) catalog_items() []host.SharedRelay {
	if app.environment_id == '' { return app.shared_relays }
	if !app.catalog_ready() { return []host.SharedRelay{} }
	return app.server_snapshot.relay_catalog.entries
}

fn (mut app Workshop) open_relay_catalog() {
	if app.shared_scope != app.environment_id {
		app.shared_id = ''
		app.shared_token = ''
		app.shared_url = ''
		app.shared_name = ''
		app.shared_protocol = 'vhttpd'
		app.shared_message = ''
		app.shared_scope = app.environment_id
	}
	app.workspace_page = .relay
	app.show_shared_relays = true
	app.show_remote = false
	app.show_runtime = false
	app.show_component_install = false
	app.show_deployment = false
	app.close_auxiliary_project_views()
	if app.environment_id != '' { app.catalog_command(.relay_load) }
	app.select_initial_shared_relay()
}

fn (mut app Workshop) select_initial_shared_relay() {
	items := app.catalog_items()
	if app.shared_id == '' && items.len > 0 {
		app.handle_shared_relay_event('shared_pick_' + items[0].id)
	}
}

fn (mut app Workshop) catalog_command(action host.ServerAction) {
	if app.server_busy || app.server_snapshot.busy || app.shared_catalog_pending {
		app.shared_message = '服务器正在处理操作，请稍后刷新。'
		return
	}
	if !app.server_snapshot.connected || app.server_snapshot.server_id != app.environment_id {
		app.shared_message = '请先连接所选远端服务器，再刷新连接库。'
		return
	}
	if action != .relay_load && !app.catalog_ready() {
		app.shared_message = '请先刷新远端连接库。'
		return
	}
	next := app.server_sequence + 1
	select {
		app.server_worker.commands <- host.ServerCommand{ sequence: next, action: action, server: app.server_snapshot.server, shared_relay: app.shared_form(), relay_revision: app.server_snapshot.relay_catalog.revision } {
			app.server_sequence = next
			app.shared_catalog_pending = true
			app.server_busy = true
			app.shared_message = '正在读取或保存远端私有连接库…'
		}
		else {
			app.shared_message = '服务器操作队列繁忙，请稍后重试。'
		}
	}
}

fn (app &Workshop) relay_service_lines() []string {
	mut lines := relay_services_for(app.workspace_data(), app.workspace_name())
	if app.environment_id == '' && app.remote_snapshot.connected && app.remote_snapshot.workspace.known {
		lines << relay_services_for(app.remote_snapshot.workspace, '远端 · ' + app.remote_name)
	}
	return lines
}

fn relay_services_for(data host.RuntimeWorkspace, location string) []string {
	mut lines := ['环境提供的中继服务 · ' + location]
	if !data.known {
		lines << '运行状态未确认；连接运行环境后自动刷新。'
		return lines
	}
	for item in data.relays {
		mut state := if item.kind == 'hub' {
			'接收端已配置；连接数见下方运行状态'
		} else {
			'已配置；主动连接状态尚未确认'
		}
		for agent in data.relay.data.agents {
			if agent.relay_id == item.id {
				state = agent.state + ' · 尝试 ' + agent.attempt.str()
			}
		}
		lines << item.id + ' · 原生 Relay · ' + item.kind + ' · ' + state
	}
	for application in data.applications {
		for listener in application.listeners {
			if listener.control || listener.protocol != 'websocket' { continue }
			mut status := if data.websocket_known {
				'连接数未返回'
			} else {
				'连接数未确认'
			}
			for count in data.websocket_listeners {
				if listener.id in count.listener_ids {
					status = '活动连接 ' + count.active_connections.str() + ' · 房间 ' + count.active_rooms.str()
				}
			}
			lines << application.label + ' (' + application.id + ') · 应用 WebSocket · ' + listener.host + ':' + listener.port.str() + ' · ' + status
		}
	}
	if data.websocket_known {
		lines << '应用 WebSocket 合计：活动连接 ' + data.websocket_connections.str() + ' · 房间 ' + data.websocket_rooms.str() + '（不含原生 Relay 载体）'
	}
	if data.websocket_error != '' { lines << data.websocket_error }
	if data.checked_at != '' {lines << '状态更新：' + data.checked_at}
	if lines.len == 1 { lines << '当前环境未声明原生 Relay 或 WebSocket 应用服务。' }
	return lines
}

fn (mut app Workshop) poll_relay_process_logs() {
	if app.environment_id == '' || app.server_busy || app.server_snapshot.busy || !app.server_snapshot.connected || app.server_snapshot.server_id != app.environment_id || !app.remote_snapshot.connected {
		return
	}
	if !((app.workspace_page == .relay || (app.workspace_page == .logs && app.workspace_log_source == 'relay')) && !app.show_shared_relays) {
		return
	}
	if time.ticks() < app.relay_logs_next { return }
	app.relay_logs_next = time.ticks() + 3000
	next := app.server_sequence + 1
	select {
		app.server_worker.commands <- host.ServerCommand{ sequence: next, action: .relay_logs, server: app.server_snapshot.server, project_id: app.remote_snapshot.profile_id } {
			app.server_sequence = next
		}
		else {
		}
	}
}

fn shared_status_key(scope string, entry host.SharedRelay) string {
	// A successful saved connection must never lend its result to an edited draft.
	return scope + ':' + entry.id + ':' + sha256.hexhash(json.encode(entry))
}

fn (app &Workshop) shared_probe_available() bool {
	if app.shared_testing { return false }
	if app.environment_id == '' { return true }
	return app.server_snapshot.connected && app.server_snapshot.server_id == app.environment_id
		&& !app.server_busy && !app.server_snapshot.busy && !app.shared_catalog_pending
}

fn (app &Workshop) shared_probe_host() string {
	if app.environment_id == '' { return ui_text('本机') }
	for server in app.remote_servers {
		if server.id == app.environment_id { return server.name + ' (' + server.ssh_host + ')' }
	}
	if app.server_snapshot.server_id == app.environment_id {
		server := app.server_snapshot.server
		return server.name + ' (' + server.ssh_host + ')'
	}
	return app.display_environment_name()
}

fn (app &Workshop) shared_probe_description() string {
	if app.environment_id != '' && !app.shared_probe_available() && !app.shared_testing {
		return ui_text('请先连接所选远端主机，并等待当前操作完成后测试。')
	}
	return ui_text('测试发起主机：') + app.shared_probe_host() + ui_text('。未保存的草稿也可测试；测试结束自动断开，不代表配置已发布或正在连接。')
}

fn (mut app Workshop) start_shared_relay_test(entry host.SharedRelay) {
	if !app.shared_probe_available() {
		app.shared_message = app.shared_probe_description()
		return
	}
	if app.environment_id != '' {
		select {
			app.server_worker.commands <- host.ServerCommand{action: .relay_probe, server: app.server_snapshot.server, shared_relay: entry, relay_probe_reply: app.shared_results} {}
			else { app.shared_message = '服务器操作队列繁忙，请稍后重试。'; return }
		}
	} else {
		spawn test_shared_connection(entry, app.shared_results)
	}
	app.shared_testing = true
	app.shared_test_scope = app.environment_id
	app.shared_test_id = entry.id
	app.shared_test_form = entry
	app.shared_test_host = app.shared_probe_host()
	app.shared_message = ui_text('正在测试 · ') + app.shared_test_host
}
