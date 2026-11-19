module host

import admin_state_store
import crypto.sha256
import config
import json2 as json
import net.http
import os
import runtime_upgrade
import time

struct OrdinaryEndpoint {
	base  string
	token string
	root  string
}

pub struct OrdinaryLocalRequest {
pub:
	owner             McpOrdinaryRelayRequest
	restart           bool
	recoveries        []OrdinaryConfigChange
	expected_revision string
pub mut:
	reply chan OrdinaryLocalReply = chan OrdinaryLocalReply{cap: 1}
}

pub struct OrdinaryLocalReply {
	error    bool
	endpoint OrdinaryEndpoint
}

fn (mut m Manager) ordinary_local(r OrdinaryLocalRequest) !OrdinaryLocalReply {
	r.owner.check()!
	bound := r.owner.access.selection()
	if bound.application.id == '' || m.project != bound.project {
		return error('local_binding_changed')
	}
	if r.recoveries.len > 0 {
		root := os.dir(m.project.config_path)
		members := config.runtime_config_sources(m.project.config_path)!
		if runtime_upgrade.revision(m.project.config_path)! != r.expected_revision { return error('relay_offline_recovery_conflict') }
		mut changes := []admin_state_store.ConfigFileChange{}
		mut sources := map[string]string{}
		for member in members { sources[member.path] = os.read_file(member.path)! }
		for change in r.recoveries {
			if !change.path.starts_with(root + '/') { return error('relay_recovery_source_outside_environment') }
			target := development_target(root, change.path.trim_string_left(root + '/'))!
			if target != change.path || target !in sources || os.is_link(target) || sources[target] != change.original { return error('relay_offline_recovery_conflict') }
			sources[target] = change.value
			changes << admin_state_store.ConfigFileChange{path: target, original: change.original, value: change.value}
		}
		_ := config.load_runtime_plan_with_overrides(m.project.config_path, sources)!
		m.installation_stop()!
		guard := development_guard(m)!
		defer { guard.close() or {} }
		store_path := os.join_path(os.temp_dir(), 'vhttpd-relay-recovery-' + new_remote_id()!)
		mut store := admin_state_store.FileStore.new(store_path)!
		defer { os.rmdir_all(store_path) or {} }
		store.publish_config_files(changes, fn () ! {}, fn () ! {})!
		guard.close()!
	}
	if r.restart {
		m.installation_stop()!
		r.owner.check()!
		m.start(m.project, bound.binary)!
		m.installation_ready()!
	}
	if m.phase != .running || m.token == '' { return error('start_bound_runtime_first') }
	return OrdinaryLocalReply{ endpoint: OrdinaryEndpoint{ base: m.info.admin_url.all_before('/admin/ui/'), token: m.token, root: m.project.config_path } }
}

fn (r McpOrdinaryRelayRequest) local_endpoint(restart bool) !OrdinaryEndpoint {
	call := OrdinaryLocalRequest{ owner: r, restart: restart }
	select {
		r.local.ordinary_relay <- call {
		}
		else {
			return error('local_worker_busy')
		}
	}
	result := <-call.reply
	if result.error { return error('local_relay_runtime_request_failed_check_runtime') }
	return result.endpoint
}

fn ordinary_request(endpoint OrdinaryEndpoint, method http.Method, path string, body string) !string {
	mut request := http.Request{
		url:                      endpoint.base + path
		method:                   method
		data:                     if method == .post && body == '' { '{}' } else { body }
		read_timeout:             5 * time.second
		write_timeout:            5 * time.second
		allow_redirect:           false
		max_retries:              1
		disable_connection_reuse: true
	}
	request.add_custom_header('x-vhttpd-admin-token', endpoint.token)!
	request.add_custom_header('content-type', 'application/json')!
	response := request.do() or { return error('relay_admin_unavailable') }
	if response.status_code != 200 || response.body.len > 2097152 {
		return error('relay_admin_request_rejected_${response.status_code}')
	}
	return response.body
}

fn ordinary_instance(endpoint OrdinaryEndpoint) !RemoteInstance {
	instance := json.decode[RemoteInstance](ordinary_request(endpoint, .get, '/admin/workbench/instance', '')!)!
	if instance.config_path != endpoint.root || instance.boot_id == '' || !instance.ready || instance.disk_revision == '' || instance.disk_revision != instance.effective_revision {
		return error('relay_environment_not_ready_or_not_effective')
	}
	return instance
}

fn ordinary_workspace(endpoint OrdinaryEndpoint) !SharedConfigWorkspace {
	workspace := json.decode[SharedConfigWorkspace](ordinary_request(endpoint, .get, '/admin/config/workspace', '')!)!
	if workspace.config_path != endpoint.root { return error('relay_workspace_identity_changed') }
	return workspace
}

fn ordinary_draft(endpoint OrdinaryEndpoint, plan McpOrdinaryRelayPlan, restore bool) !string {
	id := 'ordinary-relay-' + plan.preview.plan_id + if restore { '-restore' } else { '' }
	ordinary_request(endpoint, .post, '/admin/config/changesets?id=' + id, json.encode(OrdinaryConfigDraft{ config_path: endpoint.root, files: ordinary_plan_changes(plan, restore) }))!
	ordinary_request(endpoint, .post, '/admin/config/changesets/' + id + '/validate', '')!
	return id
}

fn ordinary_live(endpoint OrdinaryEndpoint, id string) !string {
	if !ordinary_name(id) { return error('invalid_relay_id') }
	_ := ordinary_instance(endpoint)!
	plan := ordinary_runtime_plan(ordinary_workspace(endpoint)!)!
	raw := ordinary_request(endpoint, .get, '/admin/runtime/relay', '')!
	data := json.decode[map[string]json.Any](raw)!
	mut agents := []map[string]json.Any{}
	for entry in (data['agents'] or { json.Any([]json.Any{}) }).as_array() {
		row := entry.as_map()
		if (row['relay_id'] or { json.Any('') }).str() == id {
			agents << {
				'relay_id': json.Any(id)
				'state':    row['state'] or { json.Any('unknown') }
			}
		}
	}
	return json.encode({
		'relay_id':             json.Any(id)
		'configured':           json.Any(id in plan.relays)
		'agents':               json.decode[json.Any](json.encode(agents))!
		'carrier_count':        data['carrier_count'] or { json.Any(0) }
		'source':               json.Any('live_admin_relay')
		'process_scope_counts': json.Any(true)
	})
}

struct OrdinaryConfigChange {
	path     string
	original string
	value    string
}

struct OrdinaryConfigDraft {
	config_path string
	files       []OrdinaryConfigChange
}

fn ordinary_source_revision(workspace SharedConfigWorkspace) string {
	return shared_config_revision(workspace, '', '')
}

fn ordinary_catalog_revision(entries []SharedRelay) string {
	return sha256.hexhash(json.encode(entries))
}

fn ordinary_plan_changes(plan McpOrdinaryRelayPlan, restore bool) []OrdinaryConfigChange {
	changes := if plan.changes.len > 0 { plan.changes } else { [plan.change] }
	if restore { return changes.map(OrdinaryConfigChange{path: it.path, original: it.value, value: it.original}) }
	return changes
}

fn ordinary_changed_revision(workspace SharedConfigWorkspace, changes []OrdinaryConfigChange) string {
	mut files := workspace.files.clone()
	for i, file in files {
		for change in changes { if change.path == file.source.path { files[i] = SharedConfigSource{...file, value: change.value} } }
	}
	return ordinary_source_revision(SharedConfigWorkspace{...workspace, files: files})
}
