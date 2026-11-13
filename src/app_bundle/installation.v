module app_bundle

import app_meta
import crypto.sha256
import encoding.base64
import json2 as json
import os
import toml

// One installed copy of an app. Kept outside app.json and excluded from source
// bundles. This file and code participate in the same deployment transaction.
pub struct Installation {
pub:
	schema_version int = 1
	id             string
	app_id         string
	component      string
	entry          string
	version        string
	deployment_id  string
	fingerprint    string
	engines        []string
	files          []OwnedFile
}

pub struct OwnedFile {
pub:
	path string
	hash string
}

pub fn read_installation(root string, component string) !Installation {
	if !valid_component_id(component) { return error('invalid_component_source') }
	path := safe_target(root, 'apps/' + component + '/.vhttpd-installation.json')!
	if !os.is_file(path) || os.file_size(path) > 2097152 {
		return error('application_binding_missing')
	}
	record := json.decode[Installation](os.read_file(path)!)!
	prefix := 'apps/' + component + '/'
	if record.schema_version != 1 || !app_meta.valid_id(record.id) || !app_meta.valid_id(record.app_id) || record.component != component || !record.entry.starts_with(prefix) || !safe_path(record.entry) || record.files.len > max_files {
		return error('application_binding_invalid')
	}
	mut seen := map[string]bool{}
	for file in record.files {
		if !safe_path(file.path) || !file.path.starts_with(prefix) || file.path.to_lower() in seen || file.hash.len != 64 || !file.hash.bytes().all(it.is_hex_digit()) {
			return error('application_binding_invalid')
		}
		seen[file.path.to_lower()] = true
	}
	meta := app_meta.read(os.join_path(root, 'apps', component))!
	if meta.id != record.app_id || prefix + meta.entry != record.entry {
		return error('application_identity_changed')
	}
	return record
}

pub fn collect_component_update(root string, entry string, operation string, component string, installation_id string) !Payload {
	if !app_meta.valid_id(installation_id) { return error('application_binding_invalid') }
	p := collect_component(root, entry, operation, component)!
	app_meta.read(root)!
	return Payload{ ...p, target_installation_id: installation_id }
}

fn component_manifest(p Payload) !app_meta.Manifest {
	path := 'apps/' + p.component_id + '/app.json'
	matches := p.files.filter(it.path == path)
	if matches.len == 0 { return app_meta.Manifest{} }
	m := app_meta.parse(base64.decode_str(matches[0].data))!
	if m.icon != '' && !p.files.any(it.path == 'apps/' + p.component_id + '/' + m.icon) {
		return error('app_meta_icon_missing')
	}
	if 'apps/' + p.component_id + '/' + m.entry != p.component_entry {
		return error('app_meta_entry_mismatch')
	}
	return m
}

fn component_installation(p Payload, root string) !Installation {
	dir := safe_target(root, 'apps/' + p.component_id)!
	meta := component_manifest(p)!
	if p.target_installation_id == '' {
		if os.exists(dir) && p.adopt_engines.len == 0 { return error('component_already_installed') }
        if p.adopt_engines.len > 0 && (os.exists(os.join_path(dir,'.vhttpd-installation.json')) || os.exists(os.join_path(dir,'app.json'))) {return error('application_already_identified')}
		if meta.id != '' {
			m := meta
			// Same application in another slot is valid; each copy gets its own ID.
			return Installation{ id: installation_uuid(p.id + ':' + root), app_id: m.id, component: p.component_id, entry: p.component_entry }
		}
		return Installation{}
	}
	if !os.exists(dir) { return error('application_binding_missing') }
	old := read_installation(root, p.component_id)!
	if meta.id == '' { return error('app_meta_required') }
	m := meta
	if old.id != p.target_installation_id || old.app_id != m.id || old.entry != p.component_entry {
		return error('application_binding_mismatch')
	}
	for file in old.files {
		path := safe_target(root, file.path)!
		if !os.is_file(path) || sha256.sum(os.read_bytes(path)!).hex() != file.hash {
			return error('application_source_modified')
		}
	}
	return old
}

fn component_update_files(p Payload, root string, installation Installation) ![]File {
	mut files := p.files.clone()
	if installation.id == '' { return files }
	if p.target_installation_id != '' {
		for file in p.files {
			path := safe_target(root, file.path)!
			if os.exists(path) && !installation.files.any(it.path == file.path) {
				return error('application_unowned_file_conflict')
			}
		}
		remote := merged_config(os.join_path(root, 'vhttpd.toml'))!
		mut kept := []string{}
		for i, file in files {
			if file.path !in p.configs { continue }
			doc := toml.parse_text(base64.decode_str(file.data))!.to_any()
			// Preserve the installed listener addresses and other environment-owned
			// values. New configuration is still validated with every other app.
			text := encode_config(overlay(doc, toml.Any(remote), [], [], mut kept)!.as_map())!
			files[i] = File{ ...file, data: base64.encode_str(text), hash: sha256.hexhash(text) }
		}
	}
	m := component_manifest(p)!
	if m.id == '' { return error('app_meta_required') }
	owned := files.map(OwnedFile{ path: it.path, hash: it.hash })
	mut engines := []string{}
	for f in files {
		if f.path !in p.configs { continue }
		doc := toml.parse_text(base64.decode_str(f.data))!
		for key, _ in doc.value('engines').as_map() { if key !in engines { engines << key } }
	}
	record := Installation{ ...installation, engines: engines, version: m.version, deployment_id: p.id, fingerprint: p.fingerprint, files: owned }
	text := json.encode(record)
	files << File{ path: 'apps/' + p.component_id + '/.vhttpd-installation.json', data: base64.encode_str(text), hash: sha256.hexhash(text), mode: 0o600 }
	for prior in installation.files {
		if files.any(it.path == prior.path) { continue }
		files << File{ path: prior.path, remove: true, data: '', hash: sha256.hexhash(''), mode: 0o600 }
	}
	return files
}

fn installation_uuid(seed string) string {
	h := sha256.hexhash(seed)
	return h[..8] + '-' + h[8..12] + '-4' + h[13..16] + '-a' + h[17..20] + '-' + h[20..32]
}

pub fn payload_installation(p Payload) !Installation {
	for file in p.files {
		if os.file_name(file.path) == '.vhttpd-installation.json' && !file.remove {
			return json.decode[Installation](base64.decode_str(file.data))
		}
	}
	return Installation{}
}
