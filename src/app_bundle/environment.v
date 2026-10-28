module app_bundle

import config
import encoding.base64
import os
import toml

fn merged_config(path string) !map[string]toml.Any {
	sources := config.runtime_config_sources(path)!
	mut out := normalize_remote(toml.parse_file(path)!.to_any(), [], os.dir(path)).as_map()
	for source in sources {
		if source.path == path { continue }
		doc := normalize_remote(toml.parse_file(source.path)!.to_any(), [], os.dir(source.path)).as_map()
		for domain in ['listeners', 'engines', 'adapters', 'relays', 'providers', 'resources',
			'policies', 'transforms'] {
			if value := doc[domain] {
				out[domain] = merge_maps(out[domain] or { toml.Any(map[string]toml.Any{}) }, value)
			}
		}
	}
	return out
}

fn merge_maps(left toml.Any, right toml.Any) toml.Any {
	if left is map[string]toml.Any && right is map[string]toml.Any {
		mut out := left.clone()
		for key, val in right {
			out[key] = if before := out[key] { merge_maps(before, val) } else { val }
		}
		return out
	}
	return right
}

fn secure_subset(value toml.Any, prefix []string) toml.Any {
	if protected(prefix, value) { return value }
	if value is map[string]toml.Any {
		mut out := map[string]toml.Any{}
		for key, val in value {
			selected := secure_subset(val, child_path(prefix, key))
			if selected !is toml.Null { out[key] = selected }
		}
		if out.len > 0 { return out }
	}
	return toml.Null{}
}

fn within_component(path []string) bool {
	if path.len == 0 { return false }
	if path[0] in ['listeners', 'engines', 'adapters', 'relays', 'providers', 'transforms'] {
		return path.len >= 2
	}
	if path[0] in ['resources', 'policies'] { return path.len >= 3 }
	return path[0] in ['control', 'server', 'observability']
}

fn remote_array_value(value toml.Any, key string) toml.Any {
	if value is []toml.Any {
		for i, item in value { if array_key(item, i) == key { return item } }
	}
	return toml.Null{}
}

fn overlay(value toml.Any, remote toml.Any, prefix []string, required []string, mut kept []string) !toml.Any {
	if protected(prefix, value) || protected(prefix, remote) || prefix.join('\x1f') in required {
		if remote !is toml.Null {
			kept << prefix.join('.')
			return remote
		}
		if required.any(it == prefix.join('\x1f') || it.starts_with(prefix.join('\x1f') + '\x1f')) {
			return error('remote_credential_required')
		}
		return toml.Null{}
	}
	if value is map[string]toml.Any {
		mut out := map[string]toml.Any{}
		old := remote.as_map()
		for key, val in value {
			mapped := overlay(val, old[key] or { toml.Any(toml.Null{}) }, child_path(prefix, key), required, mut kept)!
			if mapped !is toml.Null { out[key] = mapped }
		}
		if within_component(prefix) {
			for key, val in old {
				if key in out { continue }
				selected := secure_subset(val, child_path(prefix, key))
				if selected !is toml.Null {
					out[key] = selected
					kept << child_path(prefix, key).join('.')
				}
			}
		}
		return out
	}
	if value is []toml.Any {
		mut out := []toml.Any{}
		for i, item in value {
			key := array_key(item, i)
			out << overlay(item, remote_array_value(remote, key), child_path(prefix, key), required, mut kept)!
		}
		return out
	}
	return value
}

// Apply only the target instance's environment. Local inline secrets were
// removed before transport; the target user's environment resolves ${VAR}.
pub fn preserve_remote(candidate string, p Payload, remote_config string) ![]string {
	remote := merged_config(remote_config)!
	for key in p.required {
		mut value := toml.Any(remote)
		for part in key.split('\x1f') {
			if part.starts_with('#') {
				value = remote_array_value(value, part)
			} else {
				value = value.as_map()[part] or { toml.Any(toml.Null{}) }
			}
		}
		if value is toml.Null || (value is string && value == '') {
			return error('remote_credential_required')
		}
	}
	mut local := map[string]toml.Any{}
	for rel in p.configs {
		doc := toml.parse_file(safe_target(candidate, rel)!)!.to_any().as_map()
		local = merge_maps(toml.Any(local), toml.Any(doc)).as_map()
	}
	remote_listeners := (remote['listeners'] or { toml.Any(map[string]toml.Any{}) }).as_map()
	local_listeners := (local['listeners'] or { toml.Any(map[string]toml.Any{}) }).as_map()
	if remote_listeners.len != local_listeners.len { return error('listener_mapping_required') }
	for id, item in local_listeners {
		old := remote_listeners[id] or { return error('listener_mapping_required') }
		if item.value('protocol').string() != old.value('protocol').string() {
			return error('listener_mapping_required')
		}
	}
	mut kept := []string{}
	for rel in p.configs {
		path := safe_target(candidate, rel)!
		doc := toml.parse_file(path)!.to_any()
		mut result := overlay(doc, toml.Any(remote), [], p.required, mut kept)!.as_map()
		if rel == 'vhttpd.toml' {
			if control := remote['control'] {
				result['control'] = control
				kept << 'control'
			}
			for section in ['server', 'observability'] {
				if old := remote[section] {
					selected := secure_subset(old, [section])
					if selected !is toml.Null {
						result[section] = merge_maps(result[section] or { toml.Any(map[string]toml.Any{}) }, selected)
					}
				}
			}
		}
		os.write_file(path, encode_config(result)!)!
	}
	return kept
}

// No absolute local application paths may accidentally refer to server files.
// Includes are already confined by collect(); application roots must be portable.
pub fn check_portable(p Payload) ! {
	for file in p.files {
		if file.path !in p.configs { continue }
		doc := toml.parse_text(base64_text(file.data))!
		portable_tree(doc.to_any(), [], os.dir(file.path), p)!
	}
}

fn base64_text(data string) string { return base64.decode_str(data) }

fn portable_tree(value toml.Any, prefix []string, base string, p Payload) ! {
	if value is map[string]toml.Any {
		for key, val in value {
			path := child_path(prefix, key)
			if val is string && key in ['entry', 'app_entry', 'app', 'module_root', 'build_root',
				'assets_dir', 'static_dir', 'document_root', 'root', 'signature_root'] {
				if os.is_abs_path(val) || val.contains('\\') || val.contains('$') {
					return error('absolute_application_path')
				}
				resolved := os.norm_path(os.join_path(base, val))
				if val != '' && resolved != '.' && !safe_path(resolved) {
					return error('absolute_application_path')
				}
				if key in ['entry', 'app_entry', 'app'] && val != '' && !p.files.any(it.path == resolved) {
					return error('entry_not_in_bundle')
				}
			}
			portable_tree(val, path, base, p)!
		}
	} else if value is []toml.Any {
		for val in value {
			if prefix.len > 0 && prefix.last() == 'include' && val is string && (os.is_abs_path(val) || val.contains('$') || val.contains('\\')) {
				return error('include_outside_project')
			}
			portable_tree(val, prefix, base, p)!
		}
	}
}

fn normalize_remote(value toml.Any, prefix []string, base string) toml.Any {
	if value is map[string]toml.Any {
		mut result := map[string]toml.Any{}
		for key, item in value {
			path := child_path(prefix, key)
			if item is string && (key in ['cert_file', 'key_file', 'ca_file'] || (prefix.len > 0 && prefix[0] == 'resources' && key in [
				'root',
				'socket',
				'path',
			])) && item != '' && !item.contains('$') {
				result[key] = config.resolve_config_path(base, item)
			} else {
				result[key] = normalize_remote(item, path, base)
			}
		}
		return result
	}
	return value
}
