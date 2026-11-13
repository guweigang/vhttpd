module host

import app_bundle
import config
import crypto.rand
import os
import toml

pub struct RelayDatabaseSelection {
pub:
	local_resource string
	remote_resource string
	route string
}

fn database_binding_name(value string) bool {
	return value != '' && value.len <= 100 && value.bytes().all(it.is_alnum() || it in [`_`, `-`])
}

// Keep the existing resource name and engine references. Database credentials
// are removed only from the local binding; publication owns conflict checks.
fn relay_database_changeset(path string, relay SharedRelay, selection RelayDatabaseSelection) !SharedRelayChangeset {
	relay.validate()!
	if relay.token == '' { return error('远端数据库必须使用带 Token 的 Relay。') }
	if !database_binding_name(selection.local_resource) || !selection.remote_resource.starts_with('db/') || !database_binding_name(selection.remote_resource.all_after('db/')) || selection.route == '' || selection.route.len > 128 || selection.route.bytes().any(it < 32) {
		return error('请填写本地资源名、远端 db/资源名及导出 Pipeline ID。')
	}
	root := os.abs_path(path)
	plan := config.load_runtime_plan_file(root)!
	if plan.source.schema_version != 2 { return error('远端数据库绑定需要 version = 2。') }
	resource := plan.resources['db/' + selection.local_resource] or { return error('所选项目没有这个数据库资源。') }
	if resource.kind != 'mysql' { return error('当前入口支持 MySQL 数据库资源。') }
	if existing := plan.relays[relay.relay_id] {
		if existing.mode != 'agent' || existing.options.strings['url'] != relay.url || existing.options.strings['token'] != relay.token || !existing.options.bools['autostart'] {
			return error('同名 Relay 的地址、认证或自动连接设置不同，请先在项目中调整。')
		}
	}
	mut changes := []SharedRelayFile{}
	mut overrides := map[string]string{}
	mut found := false
	for source in config.runtime_config_sources(root)! {
		original := os.read_file(source.path)!
		mut data := toml.parse_text(original)!.to_any().as_map()
		mut resources := data['resources'] or { toml.Any(map[string]toml.Any{}) }.as_map()
		mut databases := resources['db'] or { toml.Any(map[string]toml.Any{}) }.as_map()
		mut value := original
		if selection.local_resource in databases {
			if found { return error('数据库资源来源不唯一。') }
			found = true
			databases[selection.local_resource] = toml.Any({
				'kind': toml.Any('mysql')
				'options': toml.Any({
					'relay': toml.Any('relay:' + relay.relay_id)
					'route': toml.Any(selection.route)
					'remote_resource': toml.Any(selection.remote_resource)
				})
			})
			resources['db'] = toml.Any(databases)
			data['resources'] = toml.Any(resources)
			value = app_bundle.encode_config(data)!
		}
		if source.path == root && relay.relay_id !in plan.relays {
			value += shared_relay_toml(relay, relay.relay_id, 'database-' + rand.bytes(12)!.hex())!.replace('autostart = false', 'autostart = true')
		}
		if value != original {
			changes << SharedRelayFile{path: source.path, original: original, value: value}
			overrides[source.path] = value
		}
	}
	if !found { return error('找不到数据库配置文件。') }
	if changes.len == 0 { return error('项目已使用此远端数据库绑定。') }
	config.load_runtime_plan_with_overrides(root, overrides)!
	return SharedRelayChangeset{config_path: root, files: changes}
}

pub fn (mut m Manager) use_relay_database(relay SharedRelay, selection RelayDatabaseSelection) ! {
	if m.phase != .running || m.token == '' { return error('请先启动所选本地项目。') }
	bundle := relay_database_changeset(m.project.config_path, relay, selection)!
	path := m.prepare_config_changeset_login(bundle, 'relay-database-')!
	open_local(path)!
	m.message = '远端数据库草稿已打开。校验并发布后重启本地项目生效；远端须已配置对应 db-resource 导出。'
}
