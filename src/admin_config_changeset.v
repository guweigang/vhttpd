module main

import admin_state_store
import config
import json2 as json
import os
import runtime_plan
import veb

struct AdminConfigWorkspaceFile {
	source AdminConfigFileEntry
	value  string
}

struct AdminConfigPipelineBinding {
	id          string
	source_path string
	ingress     string
	egress      string
}

struct AdminConfigAdapterBinding {
	id          string
	source_path string
	kind        string
	target      string
	route       string
}

struct AdminConfigWorkspace {
	config_path string
	files       []AdminConfigWorkspaceFile
	pipelines   []AdminConfigPipelineBinding
	adapters    []AdminConfigAdapterBinding
}

struct AdminConfigChangeSet {
	config_path string
	files       []admin_state_store.ConfigFileChange
}

struct AdminConfigChangeSetResult {
	ok          bool
	draft_id    string
	config_path string
	paths       []string
	error       string
}

fn (mut app App) admin_config_workspace() !AdminConfigWorkspace {
	root := os.abs_path(app.admin_state_draft_source_path())
	files := admin_config_files_at_path(root)
	mut workspace_files := []AdminConfigWorkspaceFile{}
	for file in files {
		if file.error != '' { return error(file.error) }
		admin_state_resolve_config_file_path(root, file.path)!
		workspace_files << AdminConfigWorkspaceFile{ source: file, value: os.read_file(file.path)! }
	}
	plan := config.load_runtime_plan_file(root)!
	mut pipelines := []AdminConfigPipelineBinding{}
	for pipeline in plan.pipelines {
		owner := files.filter(pipeline.id in it.pipeline_ids)
		if owner.len != 1 { return error('config_pipeline_source_ambiguous:${pipeline.id}') }
		pipelines << AdminConfigPipelineBinding{ id: pipeline.id, source_path: owner[0].path, ingress: pipeline.ingress.str(), egress: pipeline.egress.str() }
	}
	mut adapters := []AdminConfigAdapterBinding{}
	mut adapter_ids := plan.adapters.keys()
	adapter_ids.sort()
	for id in adapter_ids {
		adapter := plan.adapters[id]
		owner := files.filter(id in it.adapter_ids)
		if owner.len != 1 { return error('config_adapter_source_ambiguous:${id}') }
		adapters << AdminConfigAdapterBinding{ id: id, source_path: owner[0].path, kind: adapter.kind, target: adapter.options.strings['target'], route: adapter.options.strings['route'] }
	}
	return AdminConfigWorkspace{ config_path: root, files: workspace_files, pipelines: pipelines, adapters: adapters }
}

fn (app &App) admin_config_changeset_overrides(bundle AdminConfigChangeSet) !map[string]string {
	root := os.abs_path(app.admin_state_draft_source_path())
	if bundle.config_path != root { return error('config_changeset_project_mismatch') }
	if bundle.files.len == 0 { return error('config_changeset_empty') }
	sources := config.runtime_config_sources(root)!
	mut values := map[string]string{}
	mut physical := map[string]bool{}
	for change in bundle.files {
		resolved := admin_state_resolve_config_file_path(root, change.path)!
		if resolved.path != change.path || !sources.any(it.path == resolved.path) {
			return error('config_changeset_source_not_in_project:${change.path}')
		}
		real := os.real_path(change.path)
		if real in physical { return error('config_changeset_duplicate_source:${change.path}') }
		physical[real] = true
		values[change.path] = change.value
	}
	return values
}

fn (mut app App) admin_config_changeset_save(id string, raw string) !AdminConfigChangeSetResult {
	bundle := json.decode[AdminConfigChangeSet](raw)!
	app.admin_config_changeset_overrides(bundle)!
	mut store := app.open_admin_state_store()!
	entry := store.put('config_changesets', admin_state_draft_id(id), json.encode(bundle))!
	return AdminConfigChangeSetResult{ ok: true, draft_id: entry.key, config_path: bundle.config_path, paths: bundle.files.map(it.path) }
}

fn (mut app App) admin_config_changeset_read(id string) !AdminConfigChangeSet {
	mut store := app.open_admin_state_store()!
	entry := store.get('config_changesets', id)!
	return json.decode[AdminConfigChangeSet](entry.value)!
}

fn (mut app App) admin_config_changeset_plan(id string) !runtime_plan.RuntimePlan {
	bundle := app.admin_config_changeset_read(id)!
	overrides := app.admin_config_changeset_overrides(bundle)!
	return config.load_runtime_plan_with_overrides(bundle.config_path, overrides)!
}

fn (mut app App) admin_config_changeset_validate(id string) AdminDraftValidationResult {
	plan := app.admin_config_changeset_plan(id) or { return AdminDraftValidationResult{ draft_id: id, error: err.msg() } }
	return AdminDraftValidationResult{ draft_id: id, ok: true, schema_version: plan.source.schema_version, counts: admin_draft_plan_counts(plan), diagnostics: plan.diagnostics }
}

fn (mut app App) admin_config_changeset_publish(id string) !AdminConfigChangeSetResult {
	bundle := app.admin_config_changeset_read(id)!
	overrides := app.admin_config_changeset_overrides(bundle)!
	root := bundle.config_path
	mut store := app.open_admin_state_store()!
	store.publish_config_files(bundle.files, fn [root, overrides] () ! {
		config.load_runtime_plan_with_overrides(root, overrides)!
	}, fn [root] () ! {
		config.load_runtime_plan_file(root)!
	})!
	store.append_event('admin.config_changeset.published', {
		'draft_id':    id
		'config_path': root
		'paths':       bundle.files.map(it.path).join(',')
	}) or {}
	app.emit('admin.config_changeset.published', {
		'draft_id':    id
		'config_path': root
	})
	return AdminConfigChangeSetResult{ ok: true, draft_id: id, config_path: root, paths: bundle.files.map(it.path) }
}

@['/admin/config/workspace'; get]
pub fn (mut app AdminApp) admin_config_workspace_get(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/config/workspace')
	if !app.admin_authorized(ctx) { return admin_plane_forbidden(mut app, mut ctx, 'GET', req) }
	result := app.shared.admin_config_workspace() or { return admin_plane_json_response(mut app, mut ctx, 'GET', req, 400, json.encode(AdminConfigChangeSetResult{ error: err.msg() }), {}) }
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(result), {})
}

@['/admin/config/changesets'; post]
pub fn (mut app AdminApp) admin_config_changesets_post(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/config/changesets')
	if !app.admin_authorized(ctx) { return admin_plane_forbidden(mut app, mut ctx, 'POST', req) }
	result := app.shared.admin_config_changeset_save(ctx.query['id'] or { '' }, ctx.req.data) or { return admin_plane_json_response(mut app, mut ctx, 'POST', req, 400, json.encode(AdminConfigChangeSetResult{ error: err.msg() }), {}) }
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 200, json.encode(result), {})
}

@['/admin/config/changesets/:id/validate'; post]
pub fn (mut app AdminApp) admin_config_changesets_validate(mut ctx Context, id string) veb.Result {
	req := admin_plane_request(ctx, '/admin/config/changesets/${id}/validate')
	if !app.admin_authorized(ctx) { return admin_plane_forbidden(mut app, mut ctx, 'POST', req) }
	result := app.shared.admin_config_changeset_validate(id)
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, if result.ok {
		200
	} else {
		422
	}, json.encode(result), {})
}

@['/admin/config/changesets/:id/diff'; get]
pub fn (mut app AdminApp) admin_config_changesets_diff(mut ctx Context, id string) veb.Result {
	req := admin_plane_request(ctx, '/admin/config/changesets/${id}/diff')
	if !app.admin_authorized(ctx) { return admin_plane_forbidden(mut app, mut ctx, 'GET', req) }
	plan := app.shared.admin_config_changeset_plan(id) or { return admin_plane_json_response(mut app, mut ctx, 'GET', req, 422, json.encode(AdminConfigChangeSetResult{ error: err.msg() }), {}) }
	result := app.shared.preview_runtime_plan_replacement_for_plan('changeset:${id}', plan)
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(result), {})
}

@['/admin/config/changesets/:id/publish'; post]
pub fn (mut app AdminApp) admin_config_changesets_publish(mut ctx Context, id string) veb.Result {
	req := admin_plane_request(ctx, '/admin/config/changesets/${id}/publish')
	if !app.admin_authorized(ctx) { return admin_plane_forbidden(mut app, mut ctx, 'POST', req) }
	result := app.shared.admin_config_changeset_publish(id) or { return admin_plane_json_response(mut app, mut ctx, 'POST', req, 422, json.encode(AdminConfigChangeSetResult{ error: err.msg() }), {}) }
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 200, json.encode(result), {})
}
