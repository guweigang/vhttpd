module host

import app_bundle
import app_meta
import json2 as json
import os
import time

pub struct McpReleaseRequest {
pub:
	target_id       string
	server_id       string
	runtime_id      string
	component       string
	installation_id string
	rollback_from   string
	plan_id         string
	action          string
	generation      u64
	deadline        i64
	access          &DevelopmentAccess    = &DevelopmentAccess{}
	reply           chan DevelopmentReply = chan DevelopmentReply{cap: 1}
}

struct McpReleasePlan {
	request McpReleaseRequest
	id      string
	expires i64
	applied bool
}

pub struct McpReleasePreview {
pub:
	plan_id                       string
	operation_id                  string
	target_id                     string
	component                     string
	installation_id               string
	version                       string
	kind                          string
	phase                         string
	expires_at                    i64
	desktop_confirmation_required bool
	runtime_impact                string
	files                         []app_bundle.FileView
}

fn (mut s ServerSession) mcp_release(req McpReleaseRequest) !string {
	selection := req.access.selection()
	if req.deadline <= time.now().unix() || req.access.is_revoked()
		|| selection.generation != req.generation || selection.application.id == '' {
		return error('stale_binding_revision: call context_get')
	}
	if !s.state.connected || s.server.id != req.server_id
		|| !s.state.projects.any(it.id == req.target_id && it.runtime_id == req.runtime_id) {
		return error('target_changed: reconnect the registered host and environment')
	}
	if req.action == 'prepare' {
		if !app_bundle.valid_component_id(req.component)
			|| (req.installation_id != '' && !app_meta.valid_id(req.installation_id))
			|| (req.rollback_from != '' && (req.rollback_from.len != 24 || !req.rollback_from.bytes().all(it.is_hex_digit()))) {
			return error('invalid_release_arguments')
		}
		app := selection.application
		meta := app_meta.read(app.root) or { return error('app_meta_required: bind an independent app with app.json') }
		if os.join_path(app.root, meta.entry) != app.config_path {
			return error('app_meta_entry_mismatch')
		}
		if s.pending_deployment.id != '' && s.pending_deployment.id != s.mcp_release_plan.id {
			return error('desktop_deployment_preview_active')
		}
		s.prepare_application(ServerCommand{
			project_id:             req.target_id
			runtime_id:             req.runtime_id
			local_project:          Project{ name: app.label, workdir: app.root, config_path: app.config_path }
			component_id:           req.component
			target_installation_id: req.installation_id
			rollback_from:          req.rollback_from
			release_app_id:         meta.id
		})!
		preview := s.state.deployment_preview
		if req.deadline <= time.now().unix() || req.access.is_revoked()
			|| req.access.selection().generation != req.generation || preview.installation.app_id != meta.id {
			s.discard_deployment()!
			return error('release_preflight_expired_or_binding_changed')
		}
		expires := time.now().unix() + 300
		s.mcp_release_plan = McpReleasePlan{ request: req, id: preview.id, expires: expires }
		report := McpReleasePreview{
			plan_id:                       preview.id
			operation_id:                  preview.id
			target_id:                     req.target_id
			component:                     req.component
			installation_id:               preview.installation.id
			version:                       preview.installation.version
			kind:                          if req.rollback_from == '' {
				'release'
			} else {
				'rollback'
			}
			phase:                         'prepared'
			expires_at:                    expires
			desktop_confirmation_required: true
			runtime_impact:                'restarts_entire_environment'
			files:                         preview.files
		}
		s.state = ServerSnapshot{ ...s.state, mcp_release_preview: report }
		return json.encode(report)
	}
	if req.action !in ['apply', 'rollback'] { return error('unknown_release_action') }
	plan := s.mcp_release_plan
	if req.plan_id == '' || req.plan_id != plan.id || req.generation != plan.request.generation
		|| voidptr(req.access) != voidptr(plan.request.access) || req.target_id != plan.request.target_id
		|| req.server_id != plan.request.server_id || req.runtime_id != plan.request.runtime_id
		|| ((req.action == 'rollback') != (plan.request.rollback_from != '')) {
		return error('invalid_release_plan')
	}
	if !plan.applied {
		if plan.expires <= time.now().unix() || s.pending_deployment.id != plan.id {
			return error('stale_release_plan: prepare again')
		}
		s.deploy_application(ServerCommand{ action: .mcp_release, deployment_id: plan.id, mcp_release: req })!
		s.mcp_release_plan = McpReleasePlan{ ...plan, applied: true }
		s.state = ServerSnapshot{ ...s.state, mcp_release_preview: McpReleasePreview{ ...s.state.mcp_release_preview, phase: 'submitted' } }
	}
	return json.encode(McpReleasePreview{
		plan_id:      plan.id
		operation_id: plan.id
		target_id:    req.target_id
		component:    plan.request.component
		kind:         if req.action == 'rollback' { 'rollback' } else { 'release' }
		phase:        'submitted'
	})
}

fn (s &ServerSession) stage_application_rollback(command ServerCommand, p RemoteProfile, dir string, id string) !string {
	if !app_bundle.valid_component_id(command.component_id) || !dir.ends_with('/' + id) {
		return error('invalid_rollback_target')
	}
	args := [os.dir(p.config_path), command.component_id, command.rollback_from,
		command.release_app_id, dir].map(shell_quote(it)).join(' ')
	checksum := s.shell(application_artifact_script(args), 30000) or {
		return error('previous_release_unavailable: select the current release of an app with a retained previous release')
	}
	return checksum.trim_space()
}

fn application_artifact_script(args string) string {
	return 'umask 077\npython3 - ' + args + " <<'VHTTPD_APP_ROLLBACK'\n" +
		$embed_file('remote_scripts/application_rollback.py').to_string() + '\nVHTTPD_APP_ROLLBACK'
}
