module host

import json2 as json
import time

pub struct McpUpgradeRequest {
pub:
	target_id         string
	server_id         string
	target_runtime_id string
	rollback_from     string
	plan_id           string
	action            string
	generation        u64
	deadline          i64
	access            &DevelopmentAccess    = &DevelopmentAccess{}
	reply             chan DevelopmentReply = chan DevelopmentReply{cap: 1}
}

pub struct UpgradeApplication {
pub:
	id    string
	label string
}

pub struct McpUpgradePreview {
pub:
	plan_id                       string
	operation_id                  string
	target_id                     string
	previous_runtime_id           string
	previous_version              string
	target_runtime_id             string
	target_version                string
	applications                  []UpgradeApplication
	kind                          string
	phase                         string
	expires_at                    i64
	desktop_confirmation_required bool
	runtime_impact                string
}

struct McpUpgradePlan {
	owner    McpUpgradeRequest
	prepared PreparedRuntimeUpgrade
	preview  McpUpgradePreview
}

fn (r McpUpgradeRequest) check_binding() ! {
	if r.deadline <= time.now().unix() || r.access.is_revoked()
		|| r.access.selection().generation != r.generation || r.access.selection().application.id == '' {
		return error('stale_binding_revision: call context_get')
	}
}

fn (mut s ServerSession) mcp_runtime_upgrade(req McpUpgradeRequest) !string {
	req.check_binding()!
	if !s.state.connected || req.server_id != s.server.id {
		return error('target_changed: reconnect the registered host')
	}
	if req.action == 'prepare' {
		s.inspect()!
		profiles := s.state.projects.filter(it.id == req.target_id)
		if profiles.len != 1 { return error('unknown_target: call targets_list') }
		profile := profiles[0]
		mut destination := req.target_runtime_id
		kind := if req.rollback_from == '' { 'upgrade' } else { 'rollback' }
		if kind == 'rollback' {
			history := s.state.upgrades.filter(it.config_path == profile.config_path
				&& it.id == req.rollback_from && it.phase == 'completed' && it.target_id == profile.runtime_id)
			if history.len != 1 {
				return error('rollback_source_not_current: use the latest completed upgrade of this target')
			}
			destination = history[0].previous_id
		}
		if !remote_runtime_id_valid(destination) {
			return error('invalid_target_runtime: call target_status')
		}
		id := new_remote_id()!
		prepared := s.prepare_runtime_upgrade(req.target_id, destination, id, true)!
		req.check_binding()!
		r := prepared.request
		preview := McpUpgradePreview{
			plan_id:                       id
			operation_id:                  id
			target_id:                     req.target_id
			previous_runtime_id:           r.previous_id
			previous_version:              r.previous_version
			target_runtime_id:             r.target_id
			target_version:                r.target_version
			applications:                  prepared.applications
			kind:                          kind
			phase:                         'prepared'
			expires_at:                    time.now().unix() + 300
			desktop_confirmation_required: true
			runtime_impact:                'restarts_entire_environment'
		}
		s.mcp_upgrade_plan = McpUpgradePlan{ owner: req, prepared: prepared, preview: preview }
		s.state = ServerSnapshot{ ...s.state, mcp_upgrade_preview: preview }
		return json.encode(preview)
	}

	plan := s.mcp_upgrade_plan
	p := plan.preview
	kind := if req.action == 'rollback' { 'rollback' } else { 'upgrade' }
	if req.action !in ['apply', 'rollback'] || req.plan_id == '' || req.plan_id != p.plan_id
		|| p.target_id != req.target_id || p.kind != kind || plan.owner.generation != req.generation
		|| voidptr(plan.owner.access) != voidptr(req.access) {
		return error('invalid_upgrade_plan: prepare again')
	}
	if p.phase == 'submitted' { return json.encode(p) }
	if p.expires_at <= time.now().unix() { return error('stale_upgrade_plan: prepare again') }
	s.inspect()!
	// A lost SSH acknowledgement must never cause a second launch.
	if !s.state.upgrades.any(it.id == p.operation_id && it.config_path == plan.prepared.request.config_path) {
		fresh := s.prepare_runtime_upgrade(req.target_id, p.target_runtime_id, p.operation_id, true)!
		if fresh.request != plan.prepared.request || fresh.binary_digest != plan.prepared.binary_digest {
			return error('stale_upgrade_plan: target, package or effective configuration changed')
		}
		if kind == 'rollback' && !s.state.upgrades.any(it.id == plan.owner.rollback_from
			&& it.config_path == fresh.request.config_path && it.phase == 'completed'
			&& it.target_id == fresh.request.previous_id && it.previous_id == fresh.request.target_id) {
			return error('rollback_source_not_current: prepare again')
		}
		req.check_binding()!
		if p.expires_at <= time.now().unix() { return error('stale_upgrade_plan: prepare again') }
		s.submit_runtime_upgrade(fresh)!
	}
	submitted := McpUpgradePreview{ ...p, phase: 'submitted' }
	s.mcp_upgrade_plan = McpUpgradePlan{ ...plan, preview: submitted }
	s.state = ServerSnapshot{ ...s.state, mcp_upgrade_preview: submitted }
	return json.encode(submitted)
}
