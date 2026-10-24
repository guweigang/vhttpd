module host

import config
import crypto.rand
import json2 as json
import net.http
import os
import time

struct SharedRelayFile {
	path     string
	original string
	value    string
}

struct SharedRelayChangeset {
	config_path string
	files       []SharedRelayFile
}

pub fn (mut m Manager) prepare_shared_relay_login(r SharedRelay) !string {
	if m.phase != .running || m.token == '' {
		return error('请先启动所选项目，再选择共享连接。')
	}
	r.validate()!
	plan := config.load_runtime_plan_file(m.project.config_path)!
	if plan.source.schema_version != 2 {
		return error('共享连接需要 version = 2 的项目配置。')
	}
	id := r.relay_id
	if id in plan.relays {
		return error('项目已存在同名 Relay，请在 Admin UI 编辑现有配置。')
	}
	node := 'agent-' + rand.bytes(12)!.hex()
	original := os.read_file(m.project.config_path)!
	value := original + shared_relay_toml(r, id, node)!
	draft_id := 'shared-relay-' + rand.bytes(12)!.hex()
	origin := m.info.admin_url.all_before('/admin/ui/')
	mut request := http.Request{
		method:                   .post
		url:                      '${origin}/admin/config/changesets?id=${draft_id}'
		data:                     json.encode(SharedRelayChangeset{ config_path: m.project.config_path, files: [SharedRelayFile{ path: m.project.config_path, original: original, value: value }] })
		read_timeout:             3 * time.second
		write_timeout:            3 * time.second
		allow_redirect:           false
		max_retries:              1
		disable_connection_reuse: true
	}
	request.add_custom_header('x-vhttpd-admin-token', m.token)!
	request.add_custom_header('content-type', 'application/json')!
	response := request.do() or { return error('无法传递共享连接草稿，请检查项目管理服务。') }
	if response.status_code != 200 {
		return error('项目未接受共享连接草稿；源配置未修改。')
	}
	return m.prepare_browser_login_target('#relay-draft?id=' + draft_id)
}

pub fn (mut m Manager) use_shared_relay(r SharedRelay) ! {
	path := m.prepare_shared_relay_login(r)!
	open_local(path)!
	m.message = '共享连接已复制为项目草稿，请在 Admin UI 选择来源、绑定 Pipeline、校验和发布。'
}
