module app_bundle

import app_meta
import config
import crypto.sha256
import encoding.base64
import os
import toml

pub fn valid_component_id(id string) bool {
	return id.len > 0 && id.len <= 64 && id[0].is_alnum() && id.bytes().all(it.is_alnum() || it in [
		u8(`-`),
		`_`,
	])
}

// Components consume environment resources; they cannot redefine the control
// plane, credentials, shared resources or process lifecycle settings.
fn component_includes(value map[string]toml.Any) []toml.Any {
	if item := value['include'] {
		if item is []toml.Any { return item }
	}
	return []toml.Any{}
}

pub fn validate_component_config(text string) ! {
	doc := toml.parse_text(text)!
	for key, _ in doc.to_any().as_map() {
		if key !in ['version', 'include', 'listeners', 'engines', 'adapters', 'transforms', 'policies',
			'pipelines'] {
			return error('component_environment_definition_forbidden')
		}
	}
	for item in component_includes(doc.to_any().as_map()) {
		if item !is string { return error('invalid_component_include') }
		if !safe_path(item.string()) || item.string().contains('$') {
			return error('invalid_component_include')
		}
	}
}

fn component_configs(root string, path string, mut seen map[string]bool) ! {
	if !path.starts_with(root + '/') || os.is_link(path) || path in seen {
		return error('invalid_component_include')
	}
	rel := path[root.len + 1..]
	safe_target(root, rel)!
	doc := toml.parse_text(os.read_file(path)!)!
	validate_component_config(os.read_file(path)!)!
	for key, _ in doc.to_any().as_map() {
		if key !in ['version', 'include', 'listeners', 'engines', 'adapters', 'transforms', 'policies',
			'pipelines'] {
			return error('component_environment_definition_forbidden')
		}
	}
	seen[path] = true
	for item in component_includes(doc.to_any().as_map()) {
		if item !is string { return error('invalid_component_include') }
		value := item.string()
		if !safe_path(value) || value.contains('$') { return error('invalid_component_include') }
		component_configs(root, os.norm_path(os.join_path(os.dir(path), value)), mut seen)!
	}
}

fn component_walk(root string, relative string, configs map[string]bool, prefix string, mut files []File, mut total []int) ! {
	mut names := os.ls(os.join_path(root, relative))!
	names.sort()
	for name in names {
		if name == '.vhttpd-installation.json' || excluded(name) || name in ['.runtime', 'node_modules', 'bin', '.ok'] { continue }
		rel := if relative == '' { name } else { relative + '/' + name }
		path := safe_target(root, rel)!
		if os.is_dir(path) {
			component_walk(root, rel, configs, prefix, mut files, mut total)!
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
		files << File{ path: prefix + rel, data: base64.encode(bytes), hash: sha256.sum(bytes).hex(), mode: if os.stat(path)!.mode & 0o111 != 0 {
			0o700
		} else {
			0o600
		} }
	}
}

pub fn collect_component(root string, entry string, operation string, id string) !Payload {
	if !valid_component_id(id) || os.real_path(root) != root || os.is_link(root) || os.dir(entry) != root {
		return error('invalid_component_source')
	}
	if os.exists(os.join_path(root, 'app.json')) || os.is_link(os.join_path(root, 'app.json')) {
        meta := app_meta.read(root)!
        if meta.entry != os.file_name(entry) { return error('app_meta_entry_mismatch') }
    }
	mut configs := map[string]bool{}
	component_configs(root, entry, mut configs)!
	mut files := []File{}
	mut total := [0]
	prefix := 'apps/' + id + '/'
	component_walk(root, '', configs, prefix, mut files, mut total)!
	mut paths := configs.keys().map(prefix + it[root.len + 1..])
	paths.sort()
	fingerprint := sha256.hexhash(files.map(it.path + ':' + it.hash).join('\n'))
	p := Payload{ id: operation, component_id: id, component_entry: prefix + os.file_name(entry), files: files, configs: paths, fingerprint: fingerprint }
	p.validate()!
	check_portable(p)!
	return p
}

// Change only the root include declaration; retain all other bytes, including
// comments, environment bindings and private resource values.
pub fn append_component_include(text string, entry string) !string {
	doc := toml.parse_text(text)!
	mut includes := component_includes(doc.to_any().as_map())
	if includes.any(it.string() == entry) { return error('component_already_installed') }
	includes << toml.Any(entry)
	declaration := 'include = ' + encode_value(toml.Any(includes)) + '\n'
	if doc.value_opt('include') == none { return declaration + text }
	lines := text.split('\n')
	mut offset := 0
	for i, line in lines {
		trimmed := line.trim_space()
		if trimmed.starts_with('[') { break }
		key := trimmed.all_before('=').trim_space()
		if key in ['include', '"include"', "'include'"] && trimmed.contains('=') {
			mut end := offset
			for j in i .. lines.len {
				end += lines[j].len + 1
				piece := text[offset..if end > text.len { text.len } else { end }]
				parsed := toml.parse_text(piece) or { continue }
				if parsed.value_opt('include') != none {
					return text[..offset] + declaration + text[if end > text.len {
						text.len
					} else {
						end
					}..]
				}
			}
			return error('component_include_format')
		}
		offset += line.len + 1
	}
	return error('component_include_format')
}

// Expand a confined component into a validated installation candidate. Existing
// config sources participate in revision checks but their bytes remain unchanged.
pub fn compose_component(p Payload, config_path string) !Payload {
	p.validate()!
	if p.component_id == '' { return error('invalid_component_bundle') }
	check_portable(p)!
	for file in p.files {
		if file.path in p.configs { validate_component_config(base64.decode_str(file.data))! }
	}
	root := os.dir(config_path)
	if os.file_name(config_path) != 'vhttpd.toml' {
		return error('component_requires_environment_root')
	}
	installation := component_installation(p, root)!
    updating := p.target_installation_id != ''
    adopting := p.adopt_engines.len > 0
    if adopting {validate_adoption(p,config_path)!}
	mut files := component_update_files(p, root, installation)!
    if adopting {files = adoption_files(p,root,installation)!}
	mut configs := p.configs.clone()
	mut overrides := map[string]string{}
	for file in files {
		if file.path in p.configs {
			overrides[os.join_path(root, file.path)] = base64.decode_str(file.data)
		}
	}
	for source in config.runtime_config_sources(config_path)! {
        if (updating || adopting) && source.path.starts_with(os.join_path(root, 'apps', p.component_id) + '/') { continue }
		if !source.path.starts_with(root + '/') { return error('include_outside_project') }
		rel := source.path[root.len + 1..]
		before := os.read_file(safe_target(root, rel)!)!
		stripped := if adopting {remove_adopted_definitions(before,p)!} else {before}
        after := if source.path == config_path {
            if updating || (adopting && component_includes(toml.parse_text(before)!.to_any().as_map()).any(it.string() == p.component_entry)) {stripped} else {append_component_include(stripped,p.component_entry)!}
        } else {stripped}
		files << File{ path: rel, data: base64.encode_str(after), hash: sha256.hexhash(after), mode: if os.stat(source.path)!.mode & 0o111 != 0 {
			0o700
		} else {
			0o600
		} }
		configs << rel
		overrides[source.path] = after
	}
	plan := config.load_runtime_plan_with_overrides(config_path, overrides)!
	mut listeners := plan.listeners.values()
	for i, a in listeners {
		for b in listeners[i + 1..] {
			if a.port == b.port && a.transport == b.transport && (a.host == b.host || a.host in ['',
				'0.0.0.0', '::'] || b.host in ['', '0.0.0.0', '::']) {
				return error('component_listener_conflict')
			}
		}
	}
	// This expanded payload is internal only; the original confined component is
	// retained for preview fingerprint checks on both Desktop and remote helpers.
	return Payload{ id: p.id, files: files, configs: configs, fingerprint: p.fingerprint }
}
