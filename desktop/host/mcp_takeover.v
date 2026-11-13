module host

import config
import json2 as json
import time

pub struct McpTakeoverRequest {
pub:
	action          string
	target          RemoteProfile
	installation_id string
	auth_app_id     string
	account         string
	plan_id         string
	lease_id        string
	generation      u64
	deadline        i64
	access          &DevelopmentAccess    = &DevelopmentAccess{}
	reply           chan DevelopmentReply = chan DevelopmentReply{cap: 1}
}

pub struct McpTakeoverPreview {
pub:
	plan_id                       string
	target_id                     string
	installation_id               string
	application_id                string
	component                     string
	relay_id                      string
	local_engine_id               string
	auth_app_id                   string
	account                       string
	expires_at                    i64
	ttl_seconds                   int
	desktop_confirmation_required bool
}

struct McpTakeoverPlan {
	owner     McpTakeoverRequest
	selection TakeoverSelection
	preview   McpTakeoverPreview
	revisions []ConfigRevision
	pid       int
mut:
	lease_id  string
	attempted bool
	released  bool
}

struct McpTakeoverState {
	target_id       string
	installation_id string
	relay_id        string
	state           string
	lease_id        string
	expires_ms      i64
	local_in_flight int
}

fn (req McpTakeoverRequest) check(m &Manager) !DevelopmentSelection {
	bound := req.access.selection()
	if req.deadline <= time.now().unix() || req.access.is_revoked()
		|| bound.generation != req.generation || bound.application.id == '' || m.project != bound.project {
		return error('stale_binding_revision: call context_get')
	}
	return bound
}

fn takeover_target_matches(binding ApplicationBinding, req McpTakeoverRequest, bound DevelopmentSelection) bool {
	return binding.environment_id == req.target.id && binding.server_id == req.target.server_id
		&& binding.config_path == req.target.config_path
		&& binding.source.workdir == bound.application.root
		&& binding.source.config_path == bound.application.config_path
		&& (req.installation_id == '' || binding.installation_id == req.installation_id)
}

fn (m &Manager) resolve_mcp_takeover(req McpTakeoverRequest, bound DevelopmentSelection) !TakeoverSelection {
	if m.phase != .running || isnil(m.process) {
		return error('start the bound local environment in Desktop')
	}
	plan := config.load_runtime_plan_file(m.project.config_path)!
	relay_id := project_takeover_relay(m.project.config_path)
	if relay_id == '' { return error('configure the authenticated Relay receiver in Desktop') }
	relay := plan.relays[relay_id] or { return error('takeover_relay_missing') }
	if relay.mode != 'agent' || relay.options.strings['token'] == '' {
		return error('takeover_requires_authenticated_agent')
	}
	targets := takeover_application_targets(m.project.config_path)!
	mut matches := []TakeoverApplicationTarget{}
	for pipeline in plan.pipelines {
		if pipeline.id != 'debug/http' || pipeline.ingress.str() != 'relay:' + relay_id
			|| pipeline.egress.domain != .adapter {
			continue
		}
		adapter := plan.adapters[pipeline.egress.id] or { continue }
		if adapter.kind != 'debug-http' { continue }
		engine := adapter.engine or { continue }
		for target in targets {
			if target.local_engine == engine.id && takeover_target_matches(target.binding, req, bound) {
				matches << target
			}
		}
	}
	if matches.len != 1 {
		return error('select the installed application and configure its debug/http receiver in Desktop')
	}
	target := matches[0]
	validate_binding_source(target.binding)!
	return TakeoverSelection{
		application_id:  target.binding.app_id
		installation_id: target.binding.installation_id
		component:       target.binding.component
		local_engine_id: target.local_engine
		relay_id:        relay_id
		app_id:          req.auth_app_id
		accounts:        if req.account == '' { []string{} } else { [req.account] }
	}
}

fn (mut m Manager) mcp_takeover_status(req McpTakeoverRequest, sel TakeoverSelection) !McpTakeoverState {
	m.control_takeover('status', sel)!
	s := m.takeover_status
	if s.binding_protocol != 2 { return error('application_binding_protocol_unsupported') }
	if s.active && (s.application_id != sel.application_id || s.installation_id != sel.installation_id) {
		return error('takeover_active_for_another_application')
	}
	return McpTakeoverState{
		target_id:       req.target.id
		installation_id: sel.installation_id
		relay_id:        sel.relay_id
		state:           if s.active { 'local' } else { 'remote' }
		lease_id:        s.lease_id
		expires_ms:      s.expires_ms
		local_in_flight: s.local_in_flight
	}
}

fn (mut m Manager) mcp_takeover(req McpTakeoverRequest) !string {
	bound := req.check(m)!
	if req.action in ['status', 'prepare'] {
		sel := m.resolve_mcp_takeover(req, bound)!
		if req.action == 'status' { return json.encode(m.mcp_takeover_status(req, sel)!) }
		if req.auth_app_id == '' || req.account == '' || req.auth_app_id.len > 128 || req.account.len > 128 {
			return error('auth_app_id and account are required (1–128 bytes)')
		}
		if check_config_status(m.info.admin_url, m.token, m.project.config_path).state != .effective {
			return error('takeover_local_config_not_effective')
		}
		baseline := config_revisions(m.project.config_path)!
		status := m.mcp_takeover_status(req, sel)!
		if status.state != 'remote' || status.local_in_flight != 0 {
			return error('takeover_already_active_or_draining')
		}
		req.check(m)!
		p := McpTakeoverPreview{
			plan_id:                       new_remote_id()!
			target_id:                     req.target.id
			installation_id:               sel.installation_id
			application_id:                sel.application_id
			component:                     sel.component
			relay_id:                      sel.relay_id
			local_engine_id:               sel.local_engine_id
			auth_app_id:                   req.auth_app_id
			account:                       req.account
			expires_at:                    time.now().unix() + 300
			ttl_seconds:                   900
			desktop_confirmation_required: true
		}
		m.mcp_takeover_plan = McpTakeoverPlan{ owner: req, selection: sel, preview: p, revisions: baseline, pid: m.process.pid }
		return json.encode(p)
	}
	mut plan := m.mcp_takeover_plan
	if req.target.id != plan.owner.target.id || req.target.server_id != plan.owner.target.server_id
		|| req.target.config_path != plan.owner.target.config_path
		|| req.generation != plan.owner.generation || voidptr(req.access) != voidptr(plan.owner.access)
		|| m.phase != .running || isnil(m.process) || plan.pid != m.process.pid {
		return error('invalid_takeover_plan: prepare again')
	}
	sel := plan.selection
	if req.action == 'release' {
		if req.lease_id == '' || req.lease_id != plan.lease_id {
			return error('takeover_lease_mismatch')
		}
		status := m.mcp_takeover_status(req, sel)!
		if status.state == 'remote' { return json.encode(status) }
		if status.lease_id != req.lease_id { return error('takeover_lease_changed') }
		req.check(m)!
		m.control_takeover('stop', sel)!
		status_after := m.mcp_takeover_status(req, sel)!
		if status_after.state != 'remote' {
			return error('takeover_release_unconfirmed: call takeover_status')
		}
		plan.released = true
		m.mcp_takeover_plan = plan
		return json.encode(status_after)
	}
	if req.action != 'start' || req.plan_id == '' || req.plan_id != plan.preview.plan_id || plan.released {
		return error('invalid_takeover_plan: prepare again')
	}
	status := m.mcp_takeover_status(req, sel)!
	if status.state == 'local' {
		if plan.lease_id == status.lease_id || (plan.attempted && plan.lease_id == ''
			&& m.takeover_status.app_id == sel.app_id && m.takeover_status.accounts == sel.accounts) {
			plan.lease_id = status.lease_id
			m.mcp_takeover_plan = plan
			return json.encode(status)
		}
		return error('takeover_lease_changed')
	}
	if plan.lease_id != '' { return error('takeover_lease_ended: prepare again') }
	if plan.preview.expires_at <= time.now().unix() || status.local_in_flight != 0
		|| plan.revisions != config_revisions(m.project.config_path)!
		|| check_config_status(m.info.admin_url, m.token, m.project.config_path).state != .effective
		|| m.resolve_mcp_takeover(plan.owner, bound)! != sel {
		return error('stale_takeover_plan: prepare again')
	}
	req.check(m)!
	plan.attempted = true
	m.mcp_takeover_plan = plan
	m.control_takeover('start', sel)!
	live := m.takeover_status
	if !live.active || live.lease_id == '' || live.application_id != sel.application_id
		|| live.installation_id != sel.installation_id || live.app_id != sel.app_id || live.accounts != sel.accounts {
		return error('takeover_start_unconfirmed: retry the same plan to recover its lease')
	}
	plan.lease_id = live.lease_id
	m.mcp_takeover_plan = plan
	return json.encode(McpTakeoverState{
		target_id:       req.target.id
		installation_id: sel.installation_id
		relay_id:        sel.relay_id
		state:           'local'
		lease_id:        live.lease_id
		expires_ms:      live.expires_ms
		local_in_flight: live.local_in_flight
	})
}
