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
	listeners   int
	resources   int
	engines     int
	adapters    int
	transforms  int
	policies    int
	providers   int
	pipelines   int
	relays      int
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

struct AdminDraftPublishResult {
	draft_id     string
	ok           bool
	error        string
	config_path  string
	path         string
	include_path string
	updated_main bool
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

fn (mut app App) admin_state_publish_draft(id string, raw_path string) AdminDraftPublishResult {
	target_path := raw_path.trim_space()
	if target_path == '' {
		return AdminDraftPublishResult{
			draft_id:    id
			ok:          false
			error:       'admin_draft_publish_path_required'
			config_path: app.admin_state_draft_source_path()
		}
	}
	entry := app.admin_state_get_draft(id) or {
		return AdminDraftPublishResult{
			draft_id:    id
			ok:          false
			error:       err.msg()
			config_path: app.admin_state_draft_source_path()
		}
	}
	config_path := app.admin_state_draft_source_path()
	resolved := admin_state_resolve_publish_path(config_path, target_path) or {
		return AdminDraftPublishResult{
			draft_id:    id
			ok:          false
			error:       err.msg()
			config_path: config_path
		}
	}
	config.load_runtime_plan_text(entry.value, resolved.path) or {
		return AdminDraftPublishResult{
			draft_id:     id
			ok:           false
			error:        err.msg()
			config_path:  config_path
			path:         resolved.path
			include_path: resolved.include_path
		}
	}
	old_main := os.read_file(config_path) or {
		return AdminDraftPublishResult{
			draft_id:    id
			ok:          false
			error:       err.msg()
			config_path: config_path
		}
	}
	old_target_exists := os.exists(resolved.path)
	old_target := if old_target_exists { os.read_file(resolved.path) or { '' } } else { '' }
	new_main := admin_state_add_include_to_config(old_main, resolved.include_path)
	os.mkdir_all(os.dir(resolved.path)) or {
		return AdminDraftPublishResult{
			draft_id:     id
			ok:           false
			error:        err.msg()
			config_path:  config_path
			path:         resolved.path
			include_path: resolved.include_path
		}
	}
	os.write_file(resolved.path, entry.value) or {
		return AdminDraftPublishResult{
			draft_id:     id
			ok:           false
			error:        err.msg()
			config_path:  config_path
			path:         resolved.path
			include_path: resolved.include_path
		}
	}
	os.write_file(config_path, new_main) or {
		admin_state_restore_publish_target(resolved.path, old_target, old_target_exists)
		return AdminDraftPublishResult{
			draft_id:     id
			ok:           false
			error:        err.msg()
			config_path:  config_path
			path:         resolved.path
			include_path: resolved.include_path
		}
	}
	config.load_runtime_plan_file(config_path) or {
		admin_state_restore_publish_target(resolved.path, old_target, old_target_exists)
		os.write_file(config_path, old_main) or {}
		return AdminDraftPublishResult{
			draft_id:     id
			ok:           false
			error:        err.msg()
			config_path:  config_path
			path:         resolved.path
			include_path: resolved.include_path
		}
	}
	mut store := app.open_admin_state_store() or {
		return AdminDraftPublishResult{
			draft_id:     id
			ok:           false
			error:        err.msg()
			config_path:  config_path
			path:         resolved.path
			include_path: resolved.include_path
		}
	}
	store.append_event('admin.draft.published', {
		'draft_id':     id
		'path':         resolved.path
		'include_path': resolved.include_path
	}) or {}
	app.emit('admin.draft.published', {
		'draft_id':     id
		'path':         resolved.path
		'include_path': resolved.include_path
	})
	return AdminDraftPublishResult{
		draft_id:     id
		ok:           true
		config_path:  config_path
		path:         resolved.path
		include_path: resolved.include_path
		updated_main: new_main != old_main
	}
}

struct AdminDraftPublishPath {
	path         string
	include_path string
}

fn admin_state_resolve_publish_path(config_path string, raw_path string) !AdminDraftPublishPath {
	config_dir := os.dir(os.abs_path(config_path))
	repo_root := os.dir(config_dir)
	clean := raw_path.trim_space()
	target_abs := if os.is_abs_path(clean) {
		os.abs_path(clean)
	} else {
		os.abs_path(os.join_path(config_dir, clean))
	}
	separator := os.path_separator
	if target_abs == repo_root || !target_abs.starts_with(repo_root + separator) {
		return error('admin_draft_publish_path_outside_project:${clean}')
	}
	include_path := admin_state_relative_path(config_dir, target_abs)
	return AdminDraftPublishPath{
		path:         target_abs
		include_path: include_path
	}
}

fn admin_state_relative_path(base string, target string) string {
	separator := os.path_separator
	prefix := base.trim_right(separator) + separator
	if target.starts_with(prefix) {
		return './' + target[prefix.len..]
	}
	parent := os.dir(base).trim_right(separator) + separator
	if target.starts_with(parent) {
		return '../' + target[parent.len..]
	}
	return target
}

fn admin_state_add_include_to_config(text string, include_path string) string {
	needle := '"${include_path}"'
	if text.contains(needle) {
		return text
	}
	start := text.index('include = [') or { -1 }
	if start >= 0 {
		rest := text[start..]
		close_rel := rest.index(']') or { -1 }
		if close_rel >= 0 {
			close_idx := start + close_rel
			insert := '  ${needle},\n'
			return text[..close_idx] + insert + text[close_idx..]
		}
	}
	insert := 'include = [\n  ${needle},\n]\n\n'
	lines := text.split_into_lines()
	if lines.len > 0 && lines[0].trim_space().starts_with('version') {
		return lines[0] + '\n\n' + insert + lines[1..].join('\n')
	}
	return insert + text
}

fn admin_state_restore_publish_target(path string, old_value string, existed bool) {
	if existed {
		os.write_file(path, old_value) or {}
		return
	}
	if os.exists(path) {
		os.rm(path) or {}
	}
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
