module host

import json2 as json
import math
import os
import toml
import toml.ast

pub struct McpConfigEdit {
pub:
	domain string
	component string
	field []string
	value json.Any
	remove bool
}

const shared_edit_domains = ['listeners', 'resources', 'engines', 'adapters', 'transforms', 'policies', 'providers', 'pipelines', 'server', 'observability']

// Configuration identity, credentials, executable/storage paths and app sources
// stay in their dedicated workflows. Unknown option strings are not public data.
fn shared_edit_field_allowed(domain string, field []string) bool {
	if domain !in shared_edit_domains || field.len == 0 || field.len > 5 { return false }
	for key in field {
		if key.len == 0 || key.len > 128 || sensitive_config_key(key) || key in ['id', 'include', 'version', 'env', 'args', 'binary', 'entry', 'module_root', 'build_root', 'root', 'document_root', 'socket', 'socket_prefix', 'sockets', 'cert', 'cert_key', 'certificates', 'pid_file', 'event_log', 'source', 'username', 'url', 'endpoint', 'init_sql', 'runtime_plugin', 'plugin', 'hooks', 'capabilities'] { return false }
	}
	if field[0] in ['options', 'map_options', 'record_options', 'list_options'] {
		return field.len == 2 && field[1] in ['status', 'body', 'route', 'target', 'strip_prefix', 'completion_mode', 'frame_kind', 'path']
	}
	return true
}

fn shared_source_relative(workspace SharedConfigWorkspace, path string) !string {
	prefix := os.dir(workspace.config_path) + '/'
	if !path.starts_with(prefix) { return error('shared_source_outside_environment') }
	rel := path.trim_string_left(prefix)
	if rel.starts_with('apps/') || rel.split('/').any(it in ['', '.', '..'] || it.starts_with('.')) { return error('shared_environment_source_required') }
	return rel
}

fn shared_value(value json.Any, depth int) !toml.Any {
	if depth > 2 { return error('shared_config_value_too_deep') }
	return match value {
		string {
			if value.len > 8192 || value.bytes().any(it == 0) || value.contains(r'${') || value.contains('://') { return error('shared_config_private_value_requires_desktop') }
			toml.Any(value)
		}
		bool { toml.Any(value) }
		int { toml.Any(i64(value)) }
		i64 { toml.Any(value) }
		f64 {
			if math.is_nan(value) || math.is_inf(value, 0) || math.abs(value) > 9007199254740991 { return error('shared_config_invalid_number') }
			if value == math.floor(value) { toml.Any(i64(value)) } else { toml.Any(value) }
		}
		[]json.Any {
			if value.len > 64 { return error('shared_config_array_too_large') }
			mut items := []toml.Any{}
			for child in value { items << shared_value(child, depth + 1)! }
			toml.Any(items)
		}
		else { error('shared_config_scalar_or_array_required') }
	}
}

fn shared_toml_encode(value toml.Any) string {
	return match value {
		string { json.encode(value) }
		bool { value.str() }
		i64 { value.str() }
		f64 { value.str() }
		[]toml.Any { '[' + value.map(shared_toml_encode(it)).join(', ') + ']' }
		else { '' }
	}
}

fn shared_tree_get(value toml.Any, path []string) !toml.Any {
	if path.len == 0 { return value }
	if value is map[string]toml.Any { return shared_tree_get(value[path[0]] or { return error('shared_field_missing') }, path[1..])! }
	if value is []toml.Any {
		i := path[0].int()
		if i < 0 || i >= value.len || i.str() != path[0] { return error('shared_array_index_invalid') }
		return shared_tree_get(value[i], path[1..])!
	}
	return error('shared_field_parent_not_table')
}

fn shared_tree_set(value toml.Any, path []string, replacement toml.Any, remove bool) !toml.Any {
	if path.len == 0 { return replacement }
	if value is map[string]toml.Any {
		mut next := map[string]toml.Any{}
		for name, child in value { next[name] = shared_tree_copy(child) }
		key := path[0]
		if path.len == 1 {
			if remove { if key !in next { return error('shared_remove_field_missing') }; next.delete(key) } else { next[key] = shared_tree_copy(replacement) }
		} else { next[key] = shared_tree_set(next[key] or { toml.Any(map[string]toml.Any{}) }, path[1..], replacement, remove)! }
		return toml.Any(next)
	}
	if value is []toml.Any {
		mut next := value.clone()
		i := path[0].int()
		if i < 0 || i >= value.len || i.str() != path[0] { return error('shared_array_index_invalid') }
		next[i] = shared_tree_set(next[i], path[1..], replacement, remove)!
		return toml.Any(next)
	}
	return error('shared_field_parent_not_table')
}

fn shared_ast_get(value ast.Value, path []string) !ast.Value {
	if path.len == 0 { return value }
	if value is map[string]ast.Value { return shared_ast_get(value[path[0]] or { return error('shared_field_missing') }, path[1..])! }
	if value is []ast.Value {
		i := path[0].int()
		if i < 0 || i >= value.len || i.str() != path[0] { return error('shared_array_index_invalid') }
		return shared_ast_get(value[i], path[1..])!
	}
	return error('shared_field_parent_not_table')
}

fn shared_component_path(source string, edit McpConfigEdit) ![]string {
	root := toml.parse_text(source)!.to_any()
	if edit.domain == 'resources' && edit.component.starts_with('secret/') { return error('shared_config_secret_resource_protected') }
	if edit.domain in ['server', 'observability'] {
		if edit.component != '' { return error('shared_component_id_not_applicable') }
		_ := shared_tree_get(root, [edit.domain])!
		return [edit.domain]
	}
	if edit.domain == 'pipelines' {
		values := shared_tree_get(root, ['pipelines'])!
		if values !is []toml.Any { return error('shared_pipeline_missing') }
		mut indexes := []int{}
		for i, entry in values { if (entry.as_map()['id'] or { toml.Any('') }).string() == edit.component { indexes << i } }
		if indexes.len != 1 { return error('shared_pipeline_missing_or_ambiguous') }
		return ['pipelines', indexes[0].str()]
	}
	mut path := [edit.domain]
	if edit.domain in ['resources', 'policies'] {
		parts := edit.component.split('/')
		if parts.len != 2 { return error('shared_category_and_id_required') }
		path << parts
	} else { path << edit.component }
	_ := shared_tree_get(root, path)!
	return path
}

// Use scalar AST positions, and bounded bracket candidates for arrays. Every
// accepted source must match the complete expected TOML tree, not a regex diff.
fn shared_edit_text(source string, edit McpConfigEdit) !(string, toml.Any, toml.Any) {
	if !shared_edit_field_allowed(edit.domain, edit.field) { return error('shared_config_protected_or_unsupported_field') }
	doc := toml.parse_text(source)!
	base := shared_component_path(source, edit)!
	mut path := base.clone(); path << edit.field
	before := shared_tree_get(doc.to_any(), path) or { toml.Any(toml.Null{}) }
	after := if edit.remove { toml.Any(toml.Null{}) } else { shared_value(edit.value, 0)! }
	if before == after { return error('shared_config_unchanged') }
	expected := shared_tree_set(doc.to_any(), path, after, edit.remove)!
	alternate := if edit.remove { shared_tree_set(expected, base, shared_prune_empty(shared_tree_get(expected, base)!, edit.field), false)! } else { expected }
	encoded := shared_toml_encode(after)
	if current := shared_ast_get(doc.ast.table, path) {
		mut spans := [][]int{}
		match current {
			ast.Quoted, ast.Number, ast.Bool { spans << [current.pos.pos - 1, current.pos.pos - 1 + current.pos.len] }
			[]ast.Value {
				// Include empty arrays and nested/quoted bracket syntax; semantic
				// equality selects solely the identified array value.
				mut attempts := 0
				for start in 0 .. source.len {
					if source[start] != `[` { continue }
					for end in start + 1 .. source.len {
						if source[end] != `]` { continue }
						attempts++
						if attempts > 256 { return error('shared_array_edit_too_complex') }
						spans << [start, end + 1]
						if end - start > 16384 { break }
					}
				}
			}
			else { return error('shared_config_leaf_required') }
		}
		for span in spans {
			start, end := span[0], span[1]
			if start < 0 || end > source.len { continue }
			if !edit.remove {
				next := source[..start] + encoded + source[end..]
				if parsed := toml.parse_text(next) { if parsed.to_any() == expected || parsed.to_any() == alternate { return next, before, after } }
			} else {
				line := source[..start].last_index('\n') or { -1 }
				mut points := [line + 1]
				for i := start - 1; i >= line + 1; i-- { if source[i] in [u8(`{`), `,`] { points << i } }
				for point in points {
					for bounds in [[point, end], [point + 1, if end < source.len && source[end] == `,` { end + 1 } else { end }]] {
						left, right := bounds[0], bounds[1]
						if left > start { continue }
						next := source[..left] + source[right..]
						if parsed := toml.parse_text(next) { if parsed.to_any() == expected || parsed.to_any() == alternate { return next, before, after } }
					}
				}
			}
		}
		return error('shared_config_edit_syntax_unsupported')
	}
	if edit.remove { return error('shared_remove_field_missing') }
	// Try existing table/array-table boundaries. Candidate keys are relative to
	// each possible ancestor; no arbitrary file or TOML is accepted from MCP.
	mut offset := 0
	for line in source.split('\n') {
		if line.trim_space().starts_with('[') || line.contains('=') {
			point := offset + line.len
			for skip in 0 .. edit.field.len {
				assignment := edit.field[skip..].map(json.encode(it)).join('.') + ' = ' + encoded
				next := source[..point] + '\n' + assignment + source[point..]
				if parsed := toml.parse_text(next) { if parsed.to_any() == expected || parsed.to_any() == alternate { return next, before, after } }
			}
		}
		offset += line.len + 1
	}
	return error('shared_config_field_insertion_unsupported')
}

fn shared_edit_plan_guard(workspace SharedConfigWorkspace, changes []OrdinaryConfigChange) ! {
	old := ordinary_runtime_plan(workspace)!
	mut values := map[string]string{}
	for file in workspace.files { values[file.source.path] = file.value }
	for change in changes { values[change.path] = change.value }
	next := remote_runtime_plan(workspace.config_path, values)!
	if old.control != next.control { return error('shared_config_control_identity_protected') }
	if control := old.control.listener {
		if old.listeners[control.id] != next.listeners[control.id] { return error('shared_config_admin_listener_protected') }
		if old.pipelines.filter(it.ingress.domain == .listener && it.ingress.id == control.id) != next.pipelines.filter(it.ingress.domain == .listener && it.ingress.id == control.id) { return error('shared_config_admin_pipeline_protected') }
	}
	for change in changes {
		before := toml.parse_text(change.original)!.to_any().as_map()
		after := toml.parse_text(change.value)!.to_any().as_map()
		for key in ['version', 'include'] {
			if (before[key] or { toml.Any(toml.Null{}) }) != (after[key] or { toml.Any(toml.Null{}) }) { return error('shared_config_include_identity_protected') }
		}
	}
}

fn shared_public(value toml.Any, secrets []string) json.Any {
	if value is toml.Null { return json.Any('[absent]') }
	j := json.decode[json.Any](json.encode(value)) or { return json.Any('[unavailable]') }
	return json.Any(config_field_value(j, false, 'mcp-shared', secrets).text)
}

fn shared_config_secrets(workspace SharedConfigWorkspace) []string {
	mut secrets := []string{}
	for file in workspace.files {
		if doc := toml.parse_text(file.value) {
			if raw := json.decode[json.Any](json.encode(doc.to_any())) { collect_config_secrets(raw, false, mut secrets) }
		}
	}
	return secrets
}

fn shared_build_changes(workspace SharedConfigWorkspace, edits []McpConfigEdit) !([]OrdinaryConfigChange, map[string]json.Any, map[string]json.Any) {
	if edits.len == 0 || edits.len > 32 { return error('shared_config_edit_count_out_of_range') }
	mut files := workspace.files.clone()
	mut before := map[string]json.Any{}
	mut after := map[string]json.Any{}
	secrets := shared_config_secrets(workspace)
	for edit in edits {
		if !shared_edit_field_allowed(edit.domain, edit.field) { return error('shared_config_protected_or_unsupported_field') }
		label := edit.domain + '/' + edit.component + '/' + edit.field.join('.')
		if label in before { return error('shared_config_duplicate_edit') }
		mut owners := []int{}
		for i, file in files {
			if _ := shared_component_path(file.value, edit) { owners << i }
		}
		if owners.len != 1 { return error('shared_config_component_missing_or_ambiguous') }
		i := owners[0]
		_ := shared_source_relative(workspace, files[i].source.path)!
		if files[i].value.len > 262144 { return error('shared_config_source_too_large') }
		next, old_value, new_value := shared_edit_text(files[i].value, edit) or { return error(err.msg() + ':' + label) }
		before[label] = shared_public(old_value, secrets)
		after[label] = shared_public(new_value, secrets)
		files[i] = SharedConfigSource{...files[i], value: next}
	}
	mut changes := []OrdinaryConfigChange{}
	for i, file in files { if file.value != workspace.files[i].value { changes << OrdinaryConfigChange{path: file.source.path, original: workspace.files[i].value, value: file.value} } }
	shared_edit_plan_guard(workspace, changes)!
	return changes, before, after
}

fn shared_flat_fields(value toml.Any, prefix []string, mut fields map[string]json.Any, domain string, secrets []string) {
	if value is map[string]toml.Any {
		for key, child in value { mut path := prefix.clone(); path << key; shared_flat_fields(child, path, mut fields, domain, secrets) }
	} else if shared_edit_field_allowed(domain, prefix) { fields[prefix.join('.')] = shared_public(value, secrets) }
}

fn shared_components(workspace SharedConfigWorkspace) ![]map[string]json.Any {
	mut rows := []map[string]json.Any{}
	secrets := shared_config_secrets(workspace)
	for file in workspace.files {
		relative := shared_source_relative(workspace, file.source.path) or { continue }
		root := toml.parse_text(file.value)!.to_any().as_map()
		for domain in shared_edit_domains {
			value := root[domain] or { continue }
			mut components := map[string]toml.Any{}
			if domain in ['server', 'observability'] { components[''] = value }
			else if domain == 'pipelines' {
				for entry in value.array() { components[(entry.as_map()['id'] or { toml.Any('') }).string()] = entry }
			} else if domain in ['resources', 'policies'] {
				for category, entries in value.as_map() { if domain == 'resources' && category == 'secret' { continue }; for id, entry in entries.as_map() { components[category + '/' + id] = entry } }
			} else { components = value.as_map().clone() }
			for id, entry in components {
				mut fields := map[string]json.Any{}
				shared_flat_fields(entry, [], mut fields, domain, secrets)
				rows << {'domain': json.Any(domain), 'component': json.Any(id), 'source': json.Any(relative), 'fields': json.Any(fields)}
			}
		}
	}
	return rows
}

fn (mut s ServerSession) shared_config_query(r McpOrdinaryRelayRequest) !string {
	mut manager := &RemoteManager{}
	endpoint := if r.target_id == '' { r.local_endpoint(false)! } else { remote, ep := s.ordinary_remote(r.target_id)!; manager = remote; ep }
	defer { if r.target_id != '' { ordinary_close(mut manager) } }
	instance := ordinary_instance(endpoint)!
	workspace := ordinary_workspace(endpoint)!
	if ordinary_source_revision(workspace) != instance.disk_revision { return error('shared_config_source_not_effective') }
	if r.tool == 'config_history_capture' {
		id := config_archive_save(s.config_history_identity(r, endpoint.root), workspace)!
		return json.encode({'version_id': json.Any(id), 'source_revision': json.Any(instance.disk_revision), 'persisted': json.Any(true)})
	}
	rows := shared_components(workspace)!
	r.check()!
	return json.encode({'components': json.Any(rows.map(json.Any(it))), 'source_revision': json.Any(instance.disk_revision), 'domains': json.Any(shared_edit_domains.map(json.Any(it))), 'source': json.Any('live_effective_configuration')})
}

fn shared_tree_copy(value toml.Any) toml.Any {
	return match value {
		map[string]toml.Any { mut result := map[string]toml.Any{}; for key, child in value { result[key] = shared_tree_copy(child) }; toml.Any(result) }
		[]toml.Any { toml.Any(value.map(shared_tree_copy(it))) }
		else { value }
	}
}

// Removing the last dotted child may remove its implicit parent in TOML. An
// explicit empty parent is also accepted; neither form removes the component.
fn shared_prune_empty(value toml.Any, path []string) toml.Any {
	if path.len <= 1 { return value }
	if value is map[string]toml.Any {
		mut next := map[string]toml.Any{}
		for key, child in value { next[key] = shared_tree_copy(child) }
		child := next[path[0]] or { return value }
		changed := shared_prune_empty(child, path[1..])
		if changed is map[string]toml.Any { if changed.len == 0 { next.delete(path[0]); return toml.Any(next) } }
		next[path[0]] = shared_tree_copy(changed)
		return toml.Any(next)
	}
	return value
}

fn shared_protected_fields(value toml.Any, domain string, prefix []string) toml.Any {
	if value is map[string]toml.Any {
		mut kept := map[string]toml.Any{}
		for key, child in value {
			mut path := prefix.clone(); path << key
			protected := shared_protected_fields(child, domain, path)
			if protected is toml.Null { continue }
			if protected is map[string]toml.Any { if protected.len == 0 { continue } }
			kept[key] = shared_tree_copy(protected)
		}
		return toml.Any(kept)
	}
	if shared_edit_field_allowed(domain, prefix) { return toml.Any(toml.Null{}) }
	return value
}

fn shared_protected_document(source string) !toml.Any {
	mut root := toml.parse_text(source)!.to_any().as_map()
	for domain in shared_edit_domains {
		value := root[domain] or { continue }
		if domain in ['server', 'observability'] { root[domain] = shared_protected_fields(value, domain, []) }
		else if domain == 'pipelines' { root[domain] = toml.Any(value.array().map(shared_protected_fields(it, domain, []))) }
		else {
			mut entries := map[string]toml.Any{}
			for name, entry in value.as_map() {
				if domain == 'resources' && name == 'secret' { entries[name] = shared_tree_copy(entry); continue }
				if domain in ['resources', 'policies'] {
					mut category := map[string]toml.Any{}
					for id, component in entry.as_map() { category[id] = shared_protected_fields(component, domain, []) }
					entries[name] = toml.Any(category)
				} else { entries[name] = shared_protected_fields(entry, domain, []) }
			}
			root[domain] = toml.Any(entries)
		}
	}
	return toml.Any(root)
}
