module main

import config
import admin_state_store
import os
import runtime_plan
import time

struct AdminDraftDeleteResponse {
	ok       bool
	draft_id string
}

struct AdminDraftPlanCounts {
	listeners  int
	resources  int
	engines    int
	adapters   int
	transforms int
	policies   int
	providers  int
	pipelines  int
	relays     int
	diagnostics int
}

struct AdminDraftValidationResult {
	draft_id       string
	ok             bool
	error          string
	schema_version int
	counts         AdminDraftPlanCounts
	diagnostics    []runtime_plan.PlanDiagnostic
}

fn (mut app App) open_admin_state_store() !admin_state_store.FileStore {
	event_log := app.control_plane.event_log.trim_space()
	root := if event_log != '' {
		os.join_path(os.dir(event_log), 'admin')
	} else {
		os.join_path('.var', 'vhttpd', 'admin')
	}
	return admin_state_store.FileStore.new(root)
}

fn admin_state_draft_id(raw string) string {
	clean := raw.trim_space()
	if clean != '' {
		return clean
	}
	return 'draft_${time.now().unix_micro()}'
}

fn (app App) admin_state_draft_source_path() string {
	if app.plan.source.config_path.trim_space() != '' {
		return app.plan.source.config_path
	}
	return os.join_path(os.getwd(), 'admin-draft.toml')
}

fn (mut app App) admin_state_list_drafts() ![]admin_state_store.Entry {
	mut store := app.open_admin_state_store()!
	return store.list('drafts')!
}

fn (mut app App) admin_state_get_draft(id string) !admin_state_store.Entry {
	mut store := app.open_admin_state_store()!
	return store.get('drafts', id)!
}

fn (mut app App) admin_state_put_draft(id string, value string) !admin_state_store.Entry {
	draft_id := admin_state_draft_id(id)
	mut store := app.open_admin_state_store()!
	entry := store.put('drafts', draft_id, value)!
	store.append_event('admin.draft.saved', {
		'draft_id': draft_id
	}) or {}
	app.emit('admin.draft.saved', {
		'draft_id': draft_id
	})
	return entry
}

fn (mut app App) admin_state_delete_draft(id string) ! {
	mut store := app.open_admin_state_store()!
	store.delete('drafts', id)!
	store.append_event('admin.draft.deleted', {
		'draft_id': id
	}) or {}
	app.emit('admin.draft.deleted', {
		'draft_id': id
	})
}

fn (mut app App) admin_state_list_events(limit int) ![]admin_state_store.Event {
	mut store := app.open_admin_state_store()!
	return store.list_events(limit)!
}

fn (mut app App) admin_state_compile_draft(id string) !runtime_plan.RuntimePlan {
	entry := app.admin_state_get_draft(id)!
	return config.load_runtime_plan_text(entry.value, app.admin_state_draft_source_path())!
}

fn (mut app App) admin_state_validate_draft(id string) AdminDraftValidationResult {
	plan := app.admin_state_compile_draft(id) or {
		return AdminDraftValidationResult{
			draft_id: id
			ok:       false
			error:    err.msg()
		}
	}
	return AdminDraftValidationResult{
		draft_id:       id
		ok:             true
		schema_version: plan.source.schema_version
		counts:         admin_draft_plan_counts(plan)
		diagnostics:    plan.diagnostics
	}
}

fn (mut app App) admin_state_diff_draft(id string) !RuntimePlanReplacementPreview {
	next_plan := app.admin_state_compile_draft(id)!
	return app.preview_runtime_plan_replacement_for_plan('draft:${id}', next_plan)
}

fn admin_draft_plan_counts(plan runtime_plan.RuntimePlan) AdminDraftPlanCounts {
	return AdminDraftPlanCounts{
		listeners:   plan.listeners.len
		resources:   plan.resources.len
		engines:     plan.engines.len
		adapters:    plan.adapters.len
		transforms:  plan.transforms.len
		policies:    plan.policies.len
		providers:   plan.providers.len
		pipelines:   plan.pipelines.len
		relays:      plan.relays.len
		diagnostics: plan.diagnostics.len
	}
}
