module app_meta

import crypto.rand
import json2 as json
import os
import semver

// Public, portable application identity. Never contains deployment destinations
// or credentials. Names and versions may change; id survives every deployment.
pub struct Manifest {
pub:
	schema_version int = 1
	id             string
	name           string
	display_name   string
	version        string
	description    string
	author         string
	license        string
	homepage       string
	repository     string
	keywords       []string
	icon           string
	entry          string = 'component.toml'
}

pub fn valid_id(id string) bool {
	if id.len != 36 || id != id.to_lower() { return false }
	for i, c in id.bytes() {
		if i in [8, 13, 18, 23] {
			if c != `-` { return false }
		} else if !c.is_hex_digit() {
			return false
		}
	}
	return true
}

fn relative_file(path string) bool {
	return path != '' && path.len <= 512 && !os.is_abs_path(path) && !path.contains('\\') && path.split('/').all(it != '' && it !in [
		'.',
		'..',
	]) && !path.bytes().any(it < 32 || it == 127)
}

pub fn (m Manifest) validate() ! {
	if m.schema_version != 1 { return error('app_meta_schema_unsupported') }
	if !valid_id(m.id) { return error('app_meta_invalid_id') }
	if m.name.len == 0 || m.name.len > 64 || !m.name[0].is_alnum() || !m.name.bytes().all(it.is_alnum() || it in [
		`-`,
		`_`,
	]) {
		return error('app_meta_invalid_name')
	}
	if !semver.is_valid(m.version) { return error('app_meta_invalid_version') }
	if m.display_name.len > 256 || m.description.len > 4096 || m.author.len > 256 || m.license.len > 128 || m.keywords.len > 32 || m.keywords.any(it.len > 64) {
		return error('app_meta_field_limit')
	}
	for value in [m.display_name, m.description, m.author, m.license, m.homepage, m.repository,
		m.version] {
		if value.contains('\x00') { return error('app_meta_invalid_text') }
	}
	for link in [m.homepage, m.repository] {
		if link != '' && (!link.starts_with('https://') || link.len > 2048 || link.bytes().any(it < 32) || link.contains('@')) {
			return error('app_meta_invalid_url')
		}
	}
	if !relative_file(m.entry) || !m.entry.ends_with('.toml') || (m.icon != '' && !relative_file(m.icon)) {
		return error('app_meta_invalid_path')
	}
}

pub fn parse(text string) !Manifest {
	if text.len > 65536 { return error('app_meta_too_large') }
	fields := json.decode[map[string]json.Any](text) or { return error('app_meta_invalid_json') }
	for key, _ in fields {
		if key !in ['schema_version', 'id', 'name', 'display_name', 'version', 'description', 'author',
			'license', 'homepage', 'repository', 'keywords', 'icon', 'entry'] {
			return error('app_meta_unknown_field:' + key)
		}
	}
	for required in ['schema_version', 'id', 'name', 'version', 'entry'] {
		if required !in fields { return error('app_meta_missing_field:' + required) }
	}
	for key, value in fields {
		if key == 'schema_version' {
			if value !is int && value !is i64 && value !is i8 && value !is i16 && value !is i32 && value !is u8 && value !is u16 && value !is u32 && value !is u64 && value !is f64 && value !is f32 {
				return error('app_meta_invalid_type')
			}
		} else if key == 'keywords' {
			if value !is []json.Any { return error('app_meta_invalid_type') }
			for word in value.as_array() {
				if word !is string { return error('app_meta_invalid_type') }
			}
		} else if value !is string {
			return error('app_meta_invalid_type')
		}
	}
	m := json.decode[Manifest](text) or { return error('app_meta_invalid_type') }
	m.validate()!
	return m
}

pub fn read(root string) !Manifest {
	path := os.join_path(root, 'app.json')
	if os.is_link(root) || os.is_link(path) || !os.is_file(path) || os.file_size(path) > 65536 {
		return error('app_meta_missing_or_unsafe')
	}
	return parse(os.read_file(path)!)
}

// Explicit source initialization only. Never regenerate an existing identity,
// including when the existing manifest is malformed.
pub fn initialize(root string, name string, entry string) !Manifest {
	path := os.join_path(root, 'app.json')
	if os.exists(path) || os.is_link(path) { return read(root) }
	m := Manifest{ id: new_id()!, name: name, display_name: name, version: '0.1.0', entry: entry }
	m.validate()!
	mut f := os.open_file(path, 'wx', 0o644)!
	defer { f.close() }
	text := json.encode(m, prettify: true)
	if f.write_string(text + '\n')! != text.len + 1 { return error('app_meta_write_failed') }
	return m
}

// Use OS entropy; app IDs are portable UUIDs, never derived from names/paths.
pub fn new_id() !string {
	mut bytes := rand.bytes(16)!
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	h := bytes.hex()
	return h[..8] + '-' + h[8..12] + '-' + h[12..16] + '-' + h[16..20] + '-' + h[20..]
}
