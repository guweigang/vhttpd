module host

import admin_state_store
import crypto.sha256
import json2 as json
import net.http
import net.urllib
import os
import time
import toml

pub struct McpSharedConfigRequest {
pub:
	action string
	target_id string
	server_id string
	runtime_id string
	plan_id string
	pipeline string
	paths []string
	generation u64
	deadline i64
	access &DevelopmentAccess = &DevelopmentAccess{}
	reply chan DevelopmentReply = chan DevelopmentReply{cap: 1}
}

pub struct McpSharedConfigReport {
pub:
	plan_id string
	target_id string
	pipeline string
	source string
	before []string
	after []string
	phase string
	restart_required bool = true
}

struct McpSharedConfigPlan {
	request McpSharedConfigRequest
	root string
	change admin_state_store.ConfigFileChange
	boot string
	revision string
	candidate_revision string
	expires i64
mut:
	report McpSharedConfigReport
	result_revision string
}

struct SharedConfigWorkspace {
	config_path string
	files []SharedConfigSource
	pipelines []SharedConfigPipeline
}

struct SharedConfigSource {
	source SharedConfigSourcePath
	value string
}

struct SharedConfigSourcePath {
	path string
}

struct SharedConfigPipeline {
	id string
	source_path string
	ingress string
}

struct SharedConfigDraft {
	config_path string
	files []admin_state_store.ConfigFileChange
}

fn shared_config_paths_valid(paths []string) bool {
	return paths.len in 1 .. 17 && paths.all(it.len in 1 .. 257 && it.starts_with('/')
		&& !it.starts_with('//') && it.bytes().all(it.is_alnum() || it in [u8(`/`), `-`, `_`, `.`, `~`]))
}

// Edit only a dotted match.paths assignment in the identified array table.
fn shared_pipeline_edit(source string, id string, paths []string) !(string, []string) {
	if !shared_config_paths_valid(paths) { return error('invalid_pipeline_paths') }
	mut lines := source.split('\n')
	mut i := 0
	for i < lines.len {
		start := i
		i++
		if lines[start].all_before('#').trim_space() != '[[pipelines]]' { continue }
		for i < lines.len && !lines[i].trim_space().starts_with('[') { i++ }
		doc := toml.parse_text(lines[start..i].join('\n')) or { return error('unsupported_pipeline_toml') }
		entries := doc.value('pipelines').array()
		if entries.len != 1 { continue }
		entry := entries[0].as_map()
		if (entry['id'] or { toml.Any(toml.Null{}) }).string() != id { continue }
		match_fields := (entry['match'] or { toml.Any(toml.Null{}) }).as_map()
		old := (match_fields['paths'] or { toml.Any(toml.Null{}) }).array().map(it.string())
		if old == paths { return error('pipeline_paths_unchanged') }
		if !shared_config_paths_valid(old) { return error('unsupported_existing_pipeline_paths') }
		for n in start + 1 .. i {
			line := lines[n]
			if line.all_before('=').trim_space() != 'match.paths' { continue }
			// Parse the single line separately. Multiline or alternative syntax
			// is left to the Admin editor.
			_ := toml.parse_text(line) or { return error('unsupported_pipeline_paths_assignment') }
			end := line.index(']') or { return error('unsupported_pipeline_paths_assignment') }
			lines[n] = line.all_before('=') + '= ' + json.encode(paths) + line[end + 1..]
			return lines.join('\n'), old
		}
		return error('unsupported_pipeline_paths_assignment')
	}
	return error('shared_pipeline_not_found')
}

fn shared_config_revision(workspace SharedConfigWorkspace, edited_path string, edited_value string) string {
	mut entries := workspace.files.map(it.source.path + ':' + sha256.hexhash(if it.source.path == edited_path { edited_value } else { it.value }))
	entries.sort()
	return sha256.hexhash(entries.join('\n'))
}

fn shared_config_request(m &RemoteManager, method http.Method, path string, data string) !string {
	response := m.request(method, path, data) or { return error('shared_config_admin_request_failed') }
	if response.status_code != 200 || response.body.len > 2 * 1024 * 1024 {
		return error('shared_config_admin_rejected:${response.status_code}')
	}
	return response.body
}

fn shared_config_instance(m &RemoteManager) !RemoteInstance {
	raw := shared_config_request(m, .get, '/admin/workbench/instance', '')!
	return json.decode[RemoteInstance](raw) or { return error('invalid_remote_instance_state') }
}

fn shared_config_workspace(m &RemoteManager, root string) !SharedConfigWorkspace {
	raw := shared_config_request(m, .get, '/admin/config/workspace', '')!
	workspace := json.decode[SharedConfigWorkspace](raw) or { return error('invalid_remote_config_workspace') }
	if workspace.config_path != root { return error('remote_config_workspace_changed') }
	return workspace
}

fn shared_config_draft(m &RemoteManager, plan McpSharedConfigPlan, rollback bool) !string {
	id := 'desktop-config-' + plan.report.plan_id + if rollback { '-restore' } else { '' }
	change := if rollback {
		admin_state_store.ConfigFileChange{ path: plan.change.path, original: plan.change.value, value: plan.change.original }
	} else { plan.change }
	shared_config_request(m, .post, '/admin/config/changesets?id=' + urllib.query_escape(id),
		json.encode(SharedConfigDraft{config_path: plan.root, files: [change]}))!
	shared_config_request(m, .post, '/admin/config/changesets/' + id + '/validate', '')!
	return id
}

fn shared_config_guard(req McpSharedConfigRequest) ! {
	if req.deadline <= time.now().unix() || req.access.is_revoked()
		|| req.access.selection().generation != req.generation {
		return error('stale_binding_revision: call context_get')
	}
}

fn (mut s ServerSession) mcp_shared_config(req McpSharedConfigRequest) !string {
	shared_config_guard(req)!
	if !s.state.connected || s.server.id != req.server_id { return error('remote_host_disconnected') }
	targets := s.state.projects.filter(it.id == req.target_id && it.runtime_id == req.runtime_id)
	if targets.len != 1 { return error('remote_config_target_changed') }
	target := targets[0]
	root := target.config_path
	mut manager := &RemoteManager{}
	manager.connect_with_session(target, '', s.state.control_path)!
	defer {
		manager.disconnect()
		for endpoint in manager.browser_endpoints {
			mut server := endpoint.server
			server.stop()
		}
	}
	instance := shared_config_instance(manager)!
	if instance.config_path != root || !instance.manual_restart || !instance.ready || instance.disk_revision == '' {
		return error('remote_config_requires_ready_managed_instance')
	}
	if req.action == 'diff' {
		if s.mcp_config_plan.report.phase in ['publishing', 'restarting', 'rollback_publishing', 'rollback_restarting'] {
			return error('shared_config_operation_pending')
		}
		if instance.disk_revision != instance.effective_revision { return error('remote_config_not_effective') }
		workspace := shared_config_workspace(manager, root)!
		if shared_config_revision(workspace, '', '') != instance.disk_revision { return error('stale_shared_config_preview') }
		pipelines := workspace.pipelines.filter(it.id == req.pipeline && it.ingress.starts_with('listener:'))
		if pipelines.len != 1 { return error('shared_pipeline_not_found') }
		path := pipelines[0].source_path
		prefix := os.dir(root) + '/'
		relative := path.trim_string_left(prefix)
		if !path.starts_with(prefix) || relative.starts_with('apps/') || relative.split('/').any(it in ['', '.', '..']) {
			return error('shared_environment_source_required')
		}
		files := workspace.files.filter(it.source.path == path)
		if files.len != 1 || files[0].value.len > 262144 { return error('shared_pipeline_source_unavailable') }
		next, before := shared_pipeline_edit(files[0].value, req.pipeline, req.paths)!
		report := McpSharedConfigReport{plan_id: new_remote_id()!, target_id: req.target_id, pipeline: req.pipeline,
			source: relative, before: before, after: req.paths, phase: 'preview'}
		s.mcp_config_plan = McpSharedConfigPlan{request: req, root: root,
			change: admin_state_store.ConfigFileChange{path: path, original: files[0].value, value: next},
			boot: instance.boot_id, revision: instance.disk_revision, candidate_revision: shared_config_revision(workspace, path, next), expires: time.now().unix() + 300, report: report}
		return json.encode(report)
	}
	mut plan := s.mcp_config_plan
	if req.plan_id == '' || req.plan_id != plan.report.plan_id || req.target_id != plan.request.target_id
		|| req.runtime_id != plan.request.runtime_id || root != plan.root || req.generation != plan.request.generation
		|| voidptr(req.access) != voidptr(plan.request.access) {
		return error('invalid_shared_config_plan')
	}
	rollback := req.action == 'rollback'
	if (req.action == 'apply' && plan.report.phase == 'applied') || (rollback && plan.report.phase == 'rolled_back') {
		return json.encode(plan.report)
	}
	if req.action == 'preflight' {
		if plan.report.phase !in ['preview', 'prepared'] || time.now().unix() >= plan.expires
			|| instance.boot_id != plan.boot || instance.disk_revision != plan.revision || instance.effective_revision != plan.revision {
			return error('stale_shared_config_preview')
		}
		shared_config_draft(manager, plan, false)!
		plan.report = McpSharedConfigReport{...plan.report, phase: 'prepared'}
		s.mcp_config_plan = plan
		return json.encode(plan.report)
	}
	if req.action !in ['apply', 'rollback'] { return error('unknown_shared_config_action') }
	phase := if rollback { 'rollback_restarting' } else { 'restarting' }
	publishing := if rollback { 'rollback_publishing' } else { 'publishing' }
	finished := if rollback { 'rolled_back' } else { 'applied' }
	if plan.report.phase == phase {
		if instance.ready && instance.disk_revision == plan.result_revision && instance.effective_revision == plan.result_revision {
			plan.report = McpSharedConfigReport{...plan.report, phase: finished}
			s.mcp_config_plan = plan
			return json.encode(plan.report)
		}
		return error('shared_config_restart_pending: check target before retrying')
	}
	expected_phase := if rollback { 'applied' } else { 'prepared' }
	expected_revision := if rollback { plan.result_revision } else { plan.revision }
	if plan.report.phase == expected_phase {
		if instance.disk_revision != expected_revision || instance.effective_revision != expected_revision
			|| (!rollback && (instance.boot_id != plan.boot || time.now().unix() >= plan.expires)) {
			return error('stale_shared_config_preview')
		}
	} else if plan.report.phase != publishing {
		return error('shared_config_preflight_required')
	}
	workspace := shared_config_workspace(manager, root)!
	files := workspace.files.filter(it.source.path == plan.change.path)
	if files.len != 1 { return error('shared_pipeline_source_unavailable') }
	before := if rollback { plan.change.value } else { plan.change.original }
	after := if rollback { plan.change.original } else { plan.change.value }
	if files[0].value == before && instance.disk_revision == expected_revision {
		id := shared_config_draft(manager, plan, rollback)!
		shared_config_guard(req)!
		plan.report = McpSharedConfigReport{...plan.report, phase: publishing}
		s.mcp_config_plan = plan
		shared_config_request(manager, .post, '/admin/config/changesets/' + id + '/publish', '')!
	} else if plan.report.phase != publishing || files[0].value != after {
		return error('shared_config_source_changed')
	}
	next := shared_config_instance(manager)!
	expected_result := if rollback { plan.revision } else { plan.candidate_revision }
	if next.boot_id != instance.boot_id || next.disk_revision != expected_result {
		return error('shared_config_target_changed_after_publish')
	}
	plan.result_revision = next.disk_revision
	plan.report = McpSharedConfigReport{...plan.report, phase: phase}
	s.mcp_config_plan = plan
	manager.snapshot = RemoteSnapshot{profile_id: target.id, connected: true, instance: next}
	manager.restart()!
	until := time.ticks() + 65000
	for time.ticks() < until {
		time.sleep(200 * time.millisecond)
		manager.tick()
		live := manager.snapshot.instance
		if live.boot_id != next.boot_id && live.ready && live.disk_revision == plan.result_revision && live.effective_revision == plan.result_revision {
			plan.report = McpSharedConfigReport{...plan.report, phase: finished}
			s.mcp_config_plan = plan
			return json.encode(plan.report)
		}
	}
	return error('shared_config_restart_pending: check target before retrying')
}
