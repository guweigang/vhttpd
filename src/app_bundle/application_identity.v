module app_bundle

import app_meta
import config
import os
import toml

// Resolve an engine's owning component from config source ownership, never by
// engine/app display names or by an untrusted HTTP field.
pub fn engine_manifest(config_path string, engine_id string) !app_meta.Manifest {
	mut selected := app_meta.Manifest{}
	for source in config.runtime_config_sources(config_path)! {
		doc := toml.parse_text(os.read_file(source.path)!)!
		if engine_id !in doc.value('engines').as_map() { continue }
		if selected.id != '' { return error('application_binding_ambiguous') }
		root := application_source_root(source.path, os.dir(config_path))!
		if root == '' { return error('app_meta_required') }
		selected = app_meta.read(root)!
	}
	if selected.id == '' { return error('app_meta_required') }
	return selected
}

pub struct ApplicationIdentity {
pub:
	app_id          string
	installation_id string
	component       string
	entry           string
	version         string
	deployment_id   string
	fingerprint     string
}

pub fn engine_identity(config_path string, engine_id string) !ApplicationIdentity {
	for source in config.runtime_config_sources(config_path)! {
		doc := toml.parse_text(os.read_file(source.path)!)!
		if engine_id !in doc.value('engines').as_map() { continue }
		root := application_source_root(source.path, os.dir(config_path))!
		if root == '' { return ApplicationIdentity{} }
		meta := app_meta.read(root)!
		if os.exists(os.join_path(root, '.vhttpd-installation.json')) {
			record := read_installation(os.dir(os.dir(root)), os.file_name(root))!
			return ApplicationIdentity{ app_id: meta.id, installation_id: record.id, component: record.component, entry: meta.entry, version: record.version, deployment_id: record.deployment_id, fingerprint: record.fingerprint }
		}
		return ApplicationIdentity{ app_id: meta.id, entry: meta.entry, version: meta.version }
	}
	return ApplicationIdentity{}
}

// Executable ownership follows the nearest app.json above its entry. module_root
// can be a shared environment root, so it must not be treated as app identity.
pub fn entry_identity(entry string) !ApplicationIdentity {
	if entry == '' { return ApplicationIdentity{} }
	mut root := os.dir(os.abs_path(entry))
	for _ in 0 .. 32 {
		if os.exists(os.join_path(root, 'app.json')) || os.is_link(os.join_path(root, 'app.json')) {
			meta := app_meta.read(root)!
			if os.exists(os.join_path(root, '.vhttpd-installation.json')) {
				record := read_installation(os.dir(os.dir(root)), os.file_name(root))!
				return ApplicationIdentity{ app_id: meta.id, installation_id: record.id, component: record.component, entry: meta.entry, version: record.version, deployment_id: record.deployment_id, fingerprint: record.fingerprint }
			}
			return ApplicationIdentity{ app_id: meta.id, entry: meta.entry, version: meta.version }
		}
		parent := os.dir(root)
		if parent == root { break }
		root = parent
	}
	return ApplicationIdentity{}
}

pub fn application_source_root(path string, boundary string) !string {
	mut root := os.dir(os.abs_path(path))
	limit := os.abs_path(boundary)
	if boundary != '' && root != limit && !root.starts_with(limit + os.path_separator) { return '' }
	for _ in 0 .. 32 {
		if os.exists(os.join_path(root, 'app.json')) || os.is_link(os.join_path(root, 'app.json')) {
			app_meta.read(root)!
			return root
		}
		parent := os.dir(root)
		if parent == root || (boundary != '' && root == limit) { break }
		root = parent
	}
	return ''
}
