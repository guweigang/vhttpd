module host

import crypto.rand
import json2 as json
import net.urllib
import os

pub struct SharedRelay {
pub:
	relay_id string
	id       string
	name     string
	url      string
	token    string
}

pub fn (r SharedRelay) validate() ! {
	if r.relay_id == '' || r.relay_id.len > 100 || !r.relay_id.bytes().all(it.is_letter() || it.is_digit() || it in [
		`-`,
		`_`,
	]) {
		return error('请填写远端 Hub 配置中的 Relay ID（字母、数字、横线或下划线）。')
	}
	if r.name.trim_space() == '' || r.name.len > 100 {
		return error('连接名称需为 1–100 个字符。')
	}
	if r.url.len > 2048 || r.url.bytes().any(it < 32 || it == 127) {
		return error('连接地址过长或包含控制字符。')
	}
	if r.id.len != 24 || !r.id.bytes().all(it.is_hex_digit()) {
		return error('连接编号无效。')
	}
	u := urllib.parse(r.url) or { return error('请填写有效的 ws:// 或 wss:// 地址。') }
	has_user := if user := u.user { user.username != '' || user.password_set } else { false }
	if u.scheme !in ['ws', 'wss'] || u.hostname() == '' || has_user || r.url.all_after('://').all_before('/').contains('@') || u.raw_query != '' || u.fragment != '' || r.url.contains(r'${') || r.url.contains('\n') || r.url.contains('\r') {
		return error('地址需使用 ws:// 或 wss://，认证请填写 Token，不放入地址、查询参数或片段。')
	}
	if r.token.len > 4096 || r.token.contains(r'${') {
		return error('请填写实际 Token（最多 4096 字符），连接库不使用环境变量表达式。')
	}
}

pub fn new_shared_relay_id() !string { return rand.bytes(12)!.hex() }

pub fn load_shared_relays() ![]SharedRelay {
	path := os.join_path(workbench_data_dir(), 'shared-relays.json')
	if !os.exists(path) { return []SharedRelay{} }
	if os.is_link(path) { return error('共享连接文件不能是符号链接。') }
	if os.file_size(path) > 1048576 { return error('共享连接文件过大。') }
	items := json.decode[[]SharedRelay](os.read_file(path)!)!
	mut ids := map[string]bool{}
	for r in items {
		r.validate()!
		if r.id in ids { return error('共享连接编号重复。') }
		ids[r.id] = true
	}
	return items
}

pub fn save_shared_relays(items []SharedRelay) ! {
	if items.len > 128 { return error('最多保存 128 个共享连接。') }
	mut ids := map[string]bool{}
	for r in items {
		r.validate()!
		if r.id in ids { return error('共享连接编号重复。') }
		ids[r.id] = true
	}
	root := workbench_data_dir()
	os.mkdir_all(root)!
	path := os.join_path(root, 'shared-relays.json')
	if os.is_link(path) { return error('共享连接文件不能是符号链接。') }
	if os.exists(path) { load_shared_relays()! }
	tmp := path + '.' + rand.bytes(12)!.hex() + '.tmp'
	defer { os.rm(tmp) or {} }
	fd := create_project_file(tmp)!
	write_project_contents(fd, json.encode(items))!
	os.mv(tmp, path)!
}

// Import creates an independent unbound agent. The existing project changeset
// path owns validation, publication, source conflicts and effectiveness.
pub fn shared_relay_toml(r SharedRelay, relay_id string, node_id string) !string {
	r.validate()!
	if relay_id != r.relay_id { return error('项目 Relay ID 必须与远端 Hub 一致。') }
	if !relay_id.bytes().all(it.is_letter() || it.is_digit() || it in [`-`, `_`]) || relay_id == '' {
		return error('Relay ID 无效。')
	}
	return '\n[relays.${relay_id}]\nmode = "agent"\ncarrier = "websocket"\nurl = ${json.encode(r.url)}\nnode_id = ${json.encode(node_id)}\ntoken = ${json.encode(r.token)}\nautostart = false\n'
}
