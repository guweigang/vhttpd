module host

import compress.zlib
import encoding.base64
import json2 as json

pub struct RelayCatalog {
pub:
	loaded   bool
	entries  []SharedRelay
	revision string
}

struct RelayCatalogRequest {
	operation string
	revision  string
	entry     SharedRelay
}

fn (mut s ServerSession) relay_catalog_operation(command ServerCommand) ! {
	if command.server.id != s.server.id {
		return error('连接库目标与 SSH 会话不一致。')
	}
	if !s.state.connected { return error('请先连接目标服务器。') }
	operation := match command.action {
		.relay_save { 'save' }
		.relay_delete { 'delete' }
		else { 'load' }
	}
	if operation == 'save' { command.shared_relay.validate()! }
	request := RelayCatalogRequest{ operation: operation, revision: command.relay_revision, entry: command.shared_relay }
	encoded := base64.encode(zlib.compress(json.encode(request).bytes())!)
	script := "python3 - <<'VHTTPD_RELAY_CATALOG'\n" + $embed_file('remote_scripts/relay_catalog.py').to_string() + '\ncatalog_operation("' + encoded + '")\nVHTTPD_RELAY_CATALOG\n'
	raw := s.shell_limited(script, 10000, 2097152)!
	catalog := json.decode[RelayCatalog](raw) or { return error('连接库响应格式无效。') }
	if !catalog.loaded || catalog.entries.len > 128 { return error('连接库响应无效。') }
	mut ids := map[string]bool{}
	for item in catalog.entries {
		item.validate()!
		if ids[item.id] { return error('连接库编号重复。') }
		ids[item.id] = true
	}
	s.state = ServerSnapshot{ ...s.state, relay_catalog: catalog, error: false, message: if operation == 'load' {
		'远端连接库已刷新。'
	} else {
		'远端连接库已保存；运行环境配置未改变。'
	} }
}

struct RelayProcessLogs {
	text string
}

fn (mut s ServerSession) read_relay_logs(command ServerCommand) ! {
	if !s.state.connected || command.server.id != s.server.id {
		return error('日志目标与 SSH 会话不一致。')
	}
	profiles := s.state.projects.filter(it.id == command.project_id)
	if profiles.len != 1 { return error('运行环境未登记，请刷新服务器。') }
	config := profiles[0].config_path
	script := "python3 - <<'VHTTPD_RELAY_LOGS'\n" + $embed_file('remote_scripts/relay_logs.py').to_string() + '\nrelay_logs(' + json.encode(config) + ')\nVHTTPD_RELAY_LOGS\n'
	raw := s.shell_limited(script, 5000, 524288)!
	logs := json.decode[RelayProcessLogs](raw)!
	s.state = ServerSnapshot{ ...s.state, relay_logs: logs.text, relay_logs_project: command.project_id, relay_logs_error: '', error: false }
}
