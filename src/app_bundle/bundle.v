module app_bundle

import config
import crypto.sha256
import encoding.base64
import json2 as json
import os
import toml

pub const max_bytes = 64 * 1024 * 1024
pub const max_files = 4096

pub struct File {
pub:
	path string
	data string
	hash string
	mode int
}

pub struct Payload {
pub:
	protocol    int = 1
	id          string
	files       []File
	configs     []string
	required    []string
	fingerprint string
}

pub struct FileView {
pub:
	path   string
	action string
	size   int
}

pub fn safe_path(path string) bool {
	return path != '' && path.len < 1024 && !path.starts_with('/') && !path.contains('\\') && !path.bytes().any(it < 32 || it == 127) && path.split('/').all(it != '' && it !in [
		'.',
		'..',
	]) && !path.split('/').any(excluded(it))
}

pub fn excluded(name string) bool {
	return name in ['.git', '.deps', '.var', '.cache', '.bin', '.DS_Store', 'process.log', 'runtime.pid',
		'credentials.json', 'secrets.json', 'id_rsa', 'id_ed25519'] || name == '.env' || name.starts_with('.env.') || name.starts_with('.desktop-') || name.ends_with('.log') || name.ends_with('.sqlite') || name.contains('.sqlite-') || name.ends_with('.db') || name.ends_with('.pem') || name.ends_with('.key') || name.ends_with('.p12') || name.ends_with('.pfx')
}

pub fn sensitive(key string) bool {
	k := key.to_lower().replace('_', '').replace('-', '')
	return ['token', 'secret', 'password', 'passwd', 'credential', 'authorization', 'apikey',
		'accesskey', 'privatekey', 'cookie', 'passphrase', 'dsn', 'connectionstring'].any(k.contains(it))
}

fn protected(path []string, value toml.Any) bool {
	if path.len == 0 { return false }
	if sensitive(path.last()) { return true }
	if path[0] == 'control' { return true }
	if path[0] == 'listeners' && path.len >= 3 && path[2] in ['host', 'port', 'tls', 'auth', 'transport'] {
		return true
	}
	if path.len >= 2 && path[0] == 'policies' && path[1] == 'auth' { return true }
	if path[0] == 'resources' && path.len >= 3 { return true }
	if path.last() in ['url', 'endpoint', 'base_url'] { return true }
	if path[0] in ['relays', 'providers'] && path.last() in ['host', 'port', 'node_id'] {
		return true
	}
	if path[0] in ['server', 'observability'] && path.last() in ['pid_file', 'event_log'] {
		return true
	}
	if value is string {
		return value.contains('://') && (value.contains('@') || value.contains('?'))
	}
	return false
}

fn child_path(prefix []string, key string) []string {
	mut out := prefix.clone()
	out << key
	return out
}

fn array_key(value toml.Any, index int) string {
	if value is map[string]toml.Any {
		for key in ['id', 'name'] { if val := value[key] { return '#${key}=${val.string()}' } }
	}
	return '#${index}'
}

fn scrub(value toml.Any, prefix []string, mut required []string) !toml.Any {
	if value is map[string]toml.Any {
		mut out := map[string]toml.Any{}
		for key, val in value {
			if key.bytes().any(it < 32) { return error('invalid_config_key') }
			path := child_path(prefix, key)
			if protected(path, val) && val !is map[string]toml.Any && val !is []toml.Any {
				if (sensitive(key) || (val is string && val.contains('://') && (val.contains('@') || val.contains('?')))) && val.string() != '' {
					required << path.join('\x1f')
				}
				out[key] = if val is int || val is i64 {
					toml.Any(0)
				} else if val is bool {
					toml.Any(false)
				} else {
					toml.Any('')
				}
			} else {
				out[key] = scrub(val, path, mut required)!
			}
		}
		return out
	}
	if value is []toml.Any {
		mut out := []toml.Any{}
		for i, val in value {
			out << scrub(val, child_path(prefix, array_key(val, i)), mut required)!
		}
		return out
	}
	return value
}

fn key_text(key string) string {
	return if key != '' && key.bytes().all(it.is_alnum() || it in [u8(`_`), `-`]) {
		key
	} else {
		json.encode(key)
	}
}

fn encode_value(value toml.Any) string {
	if value is string { return json.encode(value) }
	if value is map[string]toml.Any {
		mut keys := value.keys()
		keys.sort()
		mut parts := []string{}
		for k in keys {
			parts << '${key_text(k)} = ${encode_value(value[k] or { toml.Any(toml.Null{}) })}'
		}
		return '{ ' + parts.join(', ') + ' }'
	}
	if value is []toml.Any { return '[' + value.map(encode_value(it)).join(', ') + ']' }
	return value.to_toml()
}

fn flat_fields(value map[string]toml.Any, prefix []string) []string {
	mut keys := value.keys()
	keys.sort()
	mut rows := []string{}
	for key in keys {
		path := child_path(prefix, key)
		val := value[key] or { toml.Any(toml.Null{}) }
		if val is map[string]toml.Any {
			rows << flat_fields(val, path)
		} else {
			rows << path.map(key_text(it)).join('.') + ' = ' + encode_value(val)
		}
	}
	return rows
}

fn emit_table(value map[string]toml.Any, prefix []string) []string {
	mut rows := []string{}
	mut keys := value.keys()
	keys.sort()
	for key in keys {
		val := value[key] or { toml.Any(toml.Null{}) }
		if val !is map[string]toml.Any && !(val is []toml.Any && val.len > 0 && val[0] is map[string]toml.Any) {
			rows << '${key_text(key)} = ${encode_value(val)}'
		}
	}
	for key in keys {
		val := value[key] or { toml.Any(toml.Null{}) }
		path := child_path(prefix, key)
		if val is map[string]toml.Any {
			rows << '\n[' + path.map(key_text(it)).join('.') + ']'
			rows << emit_table(val, path)
		} else if val is []toml.Any && val.len > 0 && val[0] is map[string]toml.Any {
			for item in val {
				if item is map[string]toml.Any {
					rows << '\n[[' + path.map(key_text(it)).join('.') + ']]'
					rows << flat_fields(item, [])
				} else {
					return []string{}
				}
			}
		}
	}
	return rows
}

pub fn encode_config(value map[string]toml.Any) !string {
	text := emit_table(value, []).join('\n') + '\n'
	// Round-trip validation catches unsupported TOML shapes before upload.
	toml.parse_text(text) or { return error('config_encoding_failed') }
	return text
}

fn walk(root string, relative string, configs map[string]bool, root_config string, mut files []File, mut originals []string, mut required []string, mut total []int) ! {
	mut names := os.ls(os.join_path(root, relative))!
	names.sort()
	for name in names {
		if excluded(name) { continue }
		rel := if relative == '' { name } else { relative + '/' + name }
		path := os.join_path(root, rel)
		if os.is_link(path) { return error('project_symlink_not_supported') }
		if os.is_dir(path) {
			walk(root, rel, configs, root_config, mut files, mut originals, mut required, mut total)!
			continue
		}
		if !os.is_file(path) { return error('project_special_file_not_supported') }
		if name.ends_with('.toml') && path !in configs { continue }
		if files.len >= max_files || os.file_size(path) > 16 * 1024 * 1024 {
			return error('application_bundle_too_large')
		}
		bytes := os.read_bytes(path)!
		total[0] += bytes.len
		if total[0] > max_bytes { return error('application_bundle_too_large') }
		originals << rel + ':' + sha256.sum(bytes).hex()
		mut contents := bytes.clone()
		if path in configs {
			doc := toml.parse_text(bytes.bytestr())!
			clean := scrub(doc.to_any(), [], mut required)!
			contents = encode_config(clean.as_map())!.bytes()
		}
		dest := if path == root_config { 'vhttpd.toml' } else { rel }
		if !safe_path(dest) { return error('unsafe_bundle_path') }
		files << File{ path: dest, data: base64.encode(contents), hash: sha256.sum(contents).hex(), mode: if os.stat(path)!.mode & 0o111 != 0 {
			0o700
		} else {
			0o600
		} }
	}
}

pub fn collect(root string, config_path string, id string) !Payload {
	if os.is_link(root) || os.real_path(root) != root || os.dir(config_path) != root || os.is_link(config_path) {
		return error('project_root_required')
	}
	if config.detect_config_version(os.read_file(config_path)!)! != 2 {
		return error('deployment_requires_v2')
	}
	config.load_runtime_plan_file(config_path) or { return error('local_project_invalid') }
	sources := config.runtime_config_sources(config_path)!
	mut configs := map[string]bool{}
	mut relative_configs := []string{}
	for source in sources {
		if !source.path.starts_with(root + '/') { return error('include_outside_project') }
		rel := if source.path == config_path { 'vhttpd.toml' } else { source.path[root.len + 1..] }
		if !safe_path(rel) { return error('unsafe_bundle_path') }
		configs[source.path] = true
		relative_configs << rel
	}
	mut files := []File{}
	mut originals := []string{}
	mut required := []string{}
	mut total := [0]
	walk(root, '', configs, config_path, mut files, mut originals, mut required, mut total)!
	originals.sort()
	p := Payload{ id: id, files: files, configs: relative_configs, required: required, fingerprint: sha256.hexhash(originals.join('\n')) }
	p.validate()!
	check_portable(p)!
	return p
}

pub fn (p Payload) validate() ! {
	if p.protocol != 1 || p.id.len != 24 || !p.id.bytes().all(it.is_hex_digit()) || p.files.len < 1 || p.files.len > max_files || p.configs.len < 1 || 'vhttpd.toml' !in p.configs {
		return error('invalid_application_bundle')
	}
	mut seen := map[string]bool{}
	mut total := 0
	for file in p.files {
		if !safe_path(file.path) || file.path.to_lower() in seen || file.mode !in [
			0o600,
			0o700,
		] || file.data.len > 24 * 1024 * 1024 {
			return error('unsafe_bundle_path')
		}
		seen[file.path.to_lower()] = true
		bytes := base64.decode(file.data)
		if base64.encode(bytes) != file.data || sha256.sum(bytes).hex() != file.hash {
			return error('bundle_checksum_mismatch')
		}
		total += bytes.len
		if total > max_bytes { return error('application_bundle_too_large') }
	}
	for path in p.configs {
		if !safe_path(path) || !p.files.any(it.path == path) {
			return error('invalid_application_bundle')
		}
	}
	// A file cannot also be a parent directory of another file.
	for file in p.files {
		if p.files.any(it.path.starts_with(file.path + '/')) {
			return error('bundle_path_conflict')
		}
	}
}

pub fn safe_target(root string, relative string) !string {
	if !safe_path(relative) { return error('unsafe_bundle_path') }
	mut current := root
	if os.is_link(current) { return error('unsafe_bundle_path') }
	for part in relative.split('/') {
		current = os.join_path(current, part)
		if os.is_link(current) { return error('unsafe_bundle_path') }
	}
	return current
}

pub fn materialize(p Payload, root string) ! {
	p.validate()!
	for file in p.files {
		path := safe_target(root, file.path)!
		os.mkdir_all(os.dir(path), mode: 0o700)!
		os.write_file_array(path, base64.decode(file.data))!
		os.chmod(path, file.mode)!
	}
}
