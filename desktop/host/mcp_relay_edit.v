module host

import json2 as json
import math
import os
import toml
import toml.ast

const relay_edit_fields = ['mode', 'carrier', 'auth', 'node_id', 'path', 'listener', 'autostart', 'max_channels', 'channel_buffer', 'reconnect_delay_ms']

fn relay_edit_values(source string, id string) !map[string]ast.Value {
	doc := toml.parse_text(source)!
	root := doc.ast.table as map[string]ast.Value
	relays := root['relays'] or { return error('relay_not_in_source') }
	if relays !is map[string]ast.Value { return error('invalid_relay_source') }
	value := relays[id] or { return error('relay_not_in_source') }
	if value !is map[string]ast.Value { return error('invalid_relay_source') }
	return value
}

fn relay_edit_sources(workspace SharedConfigWorkspace, id string) ![]SharedConfigSource {
	mut found := []SharedConfigSource{}
	for file in workspace.files {
		if _ := relay_edit_values(file.value, id) { found << file }
	}
	if found.len == 0 || found.len > 32 { return error('relay_sources_missing_or_too_many') }
	mut keys := map[string]bool{}
	for file in found {
		if file.value.len > 262144 || !file.source.path.starts_with(os.dir(workspace.config_path) + '/') { return error('relay_source_outside_environment') }
		for key, _ in relay_edit_values(file.value, id)! {
			if keys[key] { return error('relay_field_defined_in_multiple_sources') }
			keys[key] = true
		}
	}
	return found
}

fn relay_edit_toml_value(value json.Any) !toml.Any {
	return match value {
		string { toml.Any(value) }
		bool { toml.Any(value) }
		int { toml.Any(i64(value)) }
		i64 { toml.Any(value) }
		f64 {
			if math.is_nan(value) || math.is_inf(value, 0) || value < -9007199254740991 || value > 9007199254740991 || value != math.floor(value) { return error('relay_edit_integer_required') }
			toml.Any(i64(value))
		}
		else { error('relay_edit_scalar_required') }
	}
}

fn relay_edit_validate(updates map[string]json.Any) ! {
	for key, value in updates {
		if key !in relay_edit_fields { return error('unsupported_relay_edit_field') }
		if key == 'mode' {
			if value !is string || value.str() !in ['hub', 'agent'] { return error('invalid_relay_mode') }
		} else if key == 'carrier' {
			if value !is string || value.str() != 'websocket' { return error('unsupported_relay_carrier') }
		} else if key == 'autostart' {
			if value !is bool { return error('relay_edit_boolean_required') }
		} else if key in ['max_channels', 'channel_buffer', 'reconnect_delay_ms'] {
			if value !is int && value !is i64 && value !is f64 { return error('relay_edit_integer_required') }
			n := value.f64()
			maximum := if key == 'reconnect_delay_ms' { i64(300000) } else { i64(1048576) }
			if math.is_nan(n) || math.is_inf(n, 0) || n < 1 || n > maximum { return error('relay_edit_integer_out_of_range') }
			if n != math.floor(n) { return error('relay_edit_integer_required') }
		} else {
			if value !is string { return error('relay_edit_string_required') }
			if value.len == 0 || value.len > 256 || value.bytes().any(it < 32 || it == 127) || value.contains(r'${') { return error('invalid_relay_edit_string') }
			if key == 'path' && !ordinary_path(value) { return error('invalid_relay_path') }
			if key == 'listener' && !value.starts_with('listener:') { return error('invalid_relay_listener_reference') }
		}
	}
}

fn relay_edit_expected(source string, id string, key string, value json.Any) !toml.Any {
	mut root := toml.parse_text(source)!.to_any().as_map()
	mut relays := root['relays']!.as_map()
	mut entry := relays[id]!.as_map()
	entry[key] = relay_edit_toml_value(value)!
	relays[id] = toml.Any(entry)
	root['relays'] = toml.Any(relays)
	return toml.Any(root)
}

// Scalar AST spans preserve comments, quoting, whitespace and unrelated values.
// Missing fields are inserted into their explicit or inline table; a semantic
// equality check proves the selected field is the only configuration change.
fn relay_edit_scalar(source string, id string, key string, value json.Any) !string {
	fields := relay_edit_values(source, id)!
	expected := relay_edit_expected(source, id, key, value)!
	encoded := if value is f64 { i64(value).str() } else { json.encode(value) }
	if current := fields[key] {
		start, size := match current {
			ast.Quoted, ast.Bool, ast.Number { current.pos.pos - 1, current.pos.len }
			else { return error('relay_field_is_not_scalar') }
		}
		if start < 0 || size < 1 || start + size > source.len { return error('unsupported_relay_scalar_span') }
		next := source[..start] + encoded + source[start + size..]
		if toml.parse_text(next)!.to_any() != expected { return error('relay_edit_semantic_mismatch') }
		return next
	}
	mut offset := 0
	for line in source.split('\n') {
		if line.trim_space().starts_with('[') && !line.trim_space().starts_with('[[') {
			if doc := toml.parse_text(line + '\n__desktop_relay_edit_probe__ = true\n') {
				root := doc.to_any().as_map()
				relays := (root['relays'] or { toml.Any(map[string]toml.Any{}) }).as_map()
				entry := (relays[id] or { toml.Any(map[string]toml.Any{}) }).as_map()
				if '__desktop_relay_edit_probe__' in entry {
					point := offset + line.len
					next := source[..point] + '\n' + key + ' = ' + encoded + source[point..]
					if candidate := toml.parse_text(next) {
						if candidate.to_any() == expected { return next }
					}
				}
			}
		}
		offset += line.len + 1
	}
	// Dotted definitions need no table header. Full semantic equality guards
	// against accidentally modifying an implicit parent or a different table.
	assignment := 'relays.' + json.encode(id) + '.' + key + ' = ' + encoded + '\n'
	for next in [source + '\n' + assignment, assignment + source] {
		if candidate := toml.parse_text(next) {
			if candidate.to_any() == expected { return next }
		}
	}
	// Inline tables can be nested inside a relays inline table. Try only closing
	// delimiters after all selected scalar values; accept solely an exact match.
	mut end := 0
	for _, field in fields {
		match field {
			ast.Quoted, ast.Bool, ast.Number { if field.pos.pos - 1 + field.pos.len > end { end = field.pos.pos - 1 + field.pos.len } }
			else {}
		}
	}
	mut attempts := 0
	for point in end .. source.len {
		if source[point] != `}` { continue }
		attempts++
		if attempts > 32 { break }
		next := source[..point] + ', ' + key + ' = ' + encoded + source[point..]
		if candidate := toml.parse_text(next) {
			if candidate.to_any() == expected { return next }
		}
	}
	return error('relay_missing_field_insertion_unsupported')
}

fn relay_edit_safe(source string, id string) !map[string]json.Any {
	value := toml.parse_text(source)!.to_any().as_map()['relays']!.as_map()[id]!.as_map()
	mut safe := map[string]json.Any{}
	for key in ['mode', 'carrier', 'auth', 'node_id', 'path', 'listener', 'autostart', 'max_channels', 'channel_buffer', 'reconnect_delay_ms'] {
		if key !in value { continue }
		item := value[key]!
		match item {
			string { safe[key] = json.Any(item) }
			bool { safe[key] = json.Any(item) }
			i64 { safe[key] = json.Any(item) }
			else {}
		}
	}
	safe['token_present'] = json.Any((value['token'] or { toml.Any('') }).string() != '')
	safe['url_present'] = json.Any((value['url'] or { toml.Any('') }).string() != '')
	return safe
}

// Delete only the identified assignment, accepting a candidate solely when its
// full TOML tree equals the expected tree with that one field removed.
fn relay_edit_remove(source string, id string, key string) !string {
	fields := relay_edit_values(source, id)!
	current := fields[key] or { return error('relay_remove_field_missing') }
	start, size := match current {
		ast.Quoted, ast.Bool, ast.Number { current.pos.pos - 1, current.pos.len }
		else { return error('relay_remove_field_not_scalar') }
	}
	mut root := toml.parse_text(source)!.to_any().as_map()
	mut relays := root['relays']!.as_map()
	mut entry := relays[id]!.as_map()
	entry.delete(key)
	relays[id] = toml.Any(entry)
	root['relays'] = toml.Any(relays)
	expected := toml.Any(root)
	end := start + size
	if start < 0 || size < 1 || end > source.len { return error('unsupported_relay_scalar_span') }
	line := source[..start].last_index('\n') or { -1 }
	// Normal and dotted assignments: retain the inline comment and newline.
	candidate := source[..line + 1] + source[end..]
	if doc := toml.parse_text(candidate) { if doc.to_any() == expected { return candidate } }
	// Inline assignments: try delimiter boundaries, including quoted keys.
	mut attempts := 0
	for point := start - 1; point >= line + 1; point-- {
		if source[point] !in [u8(`{`), `,`] { continue }
		attempts++
		if attempts > 32 { break }
		mut after := end
		for after < source.len && source[after] in [u8(` `), `\t`, `\r`, `\n`] { after++ }
		left := if source[point] == `,` { point } else { point + 1 }
		right := if source[point] == `{` && after < source.len && source[after] == `,` { after + 1 } else { end }
		next := source[..left] + source[right..]
		if doc := toml.parse_text(next) { if doc.to_any() == expected { return next } }
	}
	return error('relay_field_removal_unsupported_syntax')
}

fn relay_edit_safe_files(files []SharedConfigSource, id string) !map[string]json.Any {
	mut result := map[string]json.Any{}
	for file in files {
		for key, value in relay_edit_safe(file.value, id)! {
			if key in ['token_present', 'url_present'] { result[key] = json.Any(value.bool() || (result[key] or { json.Any(false) }).bool()) }
			else { result[key] = value }
		}
	}
	return result
}

fn relay_edit_change(r McpOrdinaryRelayRequest, workspace SharedConfigWorkspace, connection SharedRelay) !([]OrdinaryConfigChange, map[string]json.Any, map[string]json.Any) {
	relay_edit_validate(r.updates)!
	if r.updates.len == 0 && r.remove_fields.len == 0 && r.connection_id == '' { return error('relay_edit_patch_empty') }
	mut files := relay_edit_sources(workspace, r.relay_id)!
	before := relay_edit_safe_files(files, r.relay_id)!
	mut removes := r.remove_fields.clone()
	mut updates := r.updates.clone()
	for i, key in removes {
		if key !in relay_edit_fields && key !in ['token', 'url', 'auth'] { return error('unsupported_relay_remove_field') }
		if key in updates || key in removes[..i] { return error('relay_edit_field_operation_conflict') }
	}
	mode := (updates['mode'] or { before['mode'] or { json.Any('') } }).str()
	converting := mode != (before['mode'] or { json.Any('') }).str()
	if converting {
		if mode !in ['hub', 'agent'] { return error('invalid_relay_mode') }
		if mode == 'agent' && r.connection_id == '' { return error('relay_conversion_requires_connection_reference') }
		for key in if mode == 'hub' { ['url', 'autostart', 'reconnect_delay_ms'] } else { ['listener', 'path', 'auth'] } {
			if key in updates { return error('relay_conversion_incompatible_field') }
			if key !in removes { removes << key }
		}
		updates['carrier'] = json.Any('websocket')
	}
	if r.connection_id != '' {
		connection.validate()!
		if !connection.is_native() || connection.relay_id != r.relay_id || connection.token == '' { return error('native_relay_connection_id_mismatch') }
		if 'token' in removes || (mode == 'agent' && 'url' in removes) { return error('relay_edit_field_operation_conflict') }
		updates['token'] = json.Any(connection.token)
		if mode == 'agent' { updates['url'] = json.Any(connection.url) }
	}
	mut owners := map[string]int{}
	for i, file in files { for key, _ in relay_edit_values(file.value, r.relay_id)! { owners[key] = i } }
	for key in r.remove_fields { if key !in owners { return error('relay_remove_field_missing') } }
	for key in removes {
		if key !in owners { continue }
		i := owners[key]
		files[i] = SharedConfigSource{...files[i], value: relay_edit_remove(files[i].value, r.relay_id, key)!}
	}
	mut keys := updates.keys()
	keys.sort()
	// Insert a new field in the mode's physical source; edit existing fields
	// exactly where declared, never consolidate or invent another source path.
	for key in keys {
		i := owners[key] or { owners['mode'] or { 0 } }
		files[i] = SharedConfigSource{...files[i], value: relay_edit_scalar(files[i].value, r.relay_id, key, updates[key]!)!}
	}
	after := relay_edit_safe_files(files, r.relay_id)!
	if converting && mode == 'hub' && ((after['listener'] or { json.Any('') }).str() == '' || !(after['token_present'] or { json.Any(false) }).bool()) { return error('relay_hub_conversion_requires_listener_and_authentication') }
	mut changes := []OrdinaryConfigChange{}
	mut sources := map[string]string{}
	for file in workspace.files { sources[file.source.path] = file.value }
	for file in files {
		original := workspace.files.filter(it.source.path == file.source.path)[0].value
		sources[file.source.path] = file.value
		if file.value != original { changes << OrdinaryConfigChange{path: file.source.path, original: original, value: file.value} }
	}
	if changes.len == 0 { return error('relay_edit_unchanged') }
	_ := remote_runtime_plan(workspace.config_path, sources)!
	return changes, before, after
}

fn (mut s ServerSession) relay_edit_get(r McpOrdinaryRelayRequest) !string {
	mut manager := &RemoteManager{}
	endpoint := if r.target_id == '' { r.local_endpoint(false)! } else {
		remote, ep := s.ordinary_remote(r.target_id)!
		manager = remote
		ep
	}
	defer { if r.target_id != '' { ordinary_close(mut manager) } }
	instance := ordinary_instance(endpoint)!
	workspace := ordinary_workspace(endpoint)!
	if ordinary_source_revision(workspace) != instance.disk_revision { return error('relay_source_not_effective') }
	plan := ordinary_runtime_plan(workspace)!
	if r.relay_id != '' && r.relay_id !in plan.relays { return error('unknown_relay') }
	mut rows := []map[string]json.Any{}
	for id, _ in plan.relays {
		if r.relay_id != '' && r.relay_id != id { continue }
		files := relay_edit_sources(workspace, id) or {
			rows << {'relay_id': json.Any(id), 'editable': json.Any(false), 'reason': json.Any(err.msg())}
			continue
		}
		paths := files.map(it.source.path.trim_string_left(os.dir(workspace.config_path) + '/'))
		mut field_sources := map[string]json.Any{}
		for file in files { for key, _ in relay_edit_values(file.value, id)! { if key in relay_edit_fields || key in ['token', 'url', 'auth'] { field_sources[key] = json.Any(file.source.path.trim_string_left(os.dir(workspace.config_path) + '/')) } } }
		rows << {'relay_id': json.Any(id), 'editable': json.Any(true), 'source': json.Any(paths.join(', ')), 'sources': json.Any(paths.map(json.Any(it))), 'field_sources': json.Any(field_sources), 'values': json.Any(relay_edit_safe_files(files, id)!), 'editable_fields': json.Any(relay_edit_fields.map(json.Any(it)))}
	}
	r.check()!
	return json.encode({'relays': json.Any(rows.map(json.Any(it))), 'source_revision': json.Any(instance.disk_revision)})
}

fn (mut s ServerSession) relay_edit_preflight(r McpOrdinaryRelayRequest, plan McpOrdinaryRelayPlan) ! {
	if plan.entry.id != '' && s.ordinary_connection(r.target_id, plan.entry.id)! != plan.entry {
		return error('relay_credential_reference_changed_since_preview')
	}
	mut manager := &RemoteManager{}
	endpoint := if r.target_id == '' { r.local_endpoint(false)! } else {
		remote, ep := s.ordinary_remote(r.target_id)!
		manager = remote
		ep
	}
	defer { if r.target_id != '' { ordinary_close(mut manager) } }
	instance := ordinary_instance(endpoint)!
	workspace := ordinary_workspace(endpoint)!
	if instance.boot_id != plan.boot || instance.disk_revision != plan.revision || ordinary_source_revision(workspace) != plan.revision {
		return error('relay_configuration_changed_since_preview')
	}
	ordinary_draft(endpoint, plan, false)!
	r.check()!
}
