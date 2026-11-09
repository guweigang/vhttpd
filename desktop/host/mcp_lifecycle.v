module host

import crypto.sha256
import encoding.base64
import json2 as json
import time

pub struct McpLifecycleRequest {
pub:
	tool       string
	server     RemoteServer
	target_id  string
	plan_id    string
	name       string
	template   string = 'environment'
	runtime_id string
	web_port   int
	admin_port int
	generation u64
	deadline   i64
	access     &DevelopmentAccess    = &DevelopmentAccess{}
	reply      chan DevelopmentReply = chan DevelopmentReply{cap: 1}
}

pub struct McpLifecycleReport {
pub:
	plan_id    string
	host_id    string
	target_id  string
	action     string
	name       string
	template   string
	runtime_id string
	web_port   int
	admin_port int
	expires    i64
	generation u64
}

pub struct McpHostOperation {
pub:
	operation_id string
	host_id      string
	target_id    string
	action       string
	phase        string
	error        string
	generation   u64
}

struct McpLifecyclePlan {
	request     McpLifecycleRequest
	report      McpLifecycleReport
	revision    string
	fingerprint string
mut:
	operation_id string
}

fn (r McpLifecycleRequest) check() ! {
	if r.deadline <= time.now().unix() || r.access.is_revoked() || r.access.selection().generation != r.generation {
		return error('stale_binding_revision: call context_get')
	}
}

fn (mut s ServerSession) lifecycle_profile(id string) !RemoteProfile {
	matches := s.state.projects.filter(it.id == id)
	if matches.len != 1 { return error('unknown_managed_instance') }
	p := matches[0]
	if p.runtime_id == '' || p.config_path != s.state.root + '/instances/' + p.name + '/vhttpd.toml' {
		return error('unmanaged_instance')
	}
	return p
}

fn (mut s ServerSession) lifecycle_revision(p RemoteProfile) !string {
	mut sources := map[string]string{}
	mut visiting := map[string]bool{}
	s.read_project_sources(p.config_path, mut sources, mut visiting)!
	mut keys := sources.keys()
	keys.sort()
	return sha256.sum(keys.map(it + ':' + sha256.sum(sources[it].bytes()).hex()).join('\n').bytes()).hex()
}

fn (mut s ServerSession) lifecycle_probe(r McpLifecycleRequest, action string, fingerprint string) !string {
	mut body := map[string]json.Any{}
	body['action'] = action
	if action == 'create' {
		body['name'] = r.name
		body['ports'] = json.decode[json.Any](json.encode(if r.template == 'environment' {
			[r.admin_port]
		} else {
			[r.admin_port, r.web_port]
		}))!
	} else {
		p := s.lifecycle_profile(r.target_id)!
		runtime := select_remote_runtime(s.state.runtimes, p.runtime_id)!
		body['name'] = p.name
		body['id'] = p.id
		body['runtime_id'] = p.runtime_id
		body['binary'] = runtime.path + '/vhttpd'
		body['fingerprint'] = fingerprint
	}
	script := $embed_file('remote_scripts/instance_lifecycle.py').to_string()
	// Python program and JSON are fixed quoted data; no agent-controlled shell fragments.
	command := 'printf %s ' + shell_quote(base64.encode_str(json.encode(body))) + ' | base64 -d | python3 -c ' + shell_quote(script)
	return s.shell(command, 20000) or { return error('instance_preflight_or_stop_failed') }
}

fn (mut s ServerSession) lifecycle_prepare(r McpLifecycleRequest) !string {
	r.check()!
	if !s.state.connected || s.server.id != r.server.id || s.state.busy {
		return error('connect_registered_host_first')
	}
	s.inspect()!
	if s.state.upgrades.any(!it.finished()) || s.state.deployments.any(!it.finished()) {
		return error('remote_operation_in_progress')
	}
	action := r.tool.all_before('_prepare').all_after('instance_').replace('environment_', '')
	mut name := r.name
	mut revision := ''
	mut fingerprint := ''
	mut runtime_id := r.runtime_id
	if action == 'create' {
		validate_remote_project(ServerCommand{ name: r.name, template: r.template, runtime_id: r.runtime_id, web_port: r.web_port, admin_port: r.admin_port })!
		select_remote_runtime(s.state.runtimes, r.runtime_id)!
		s.lifecycle_probe(r, 'create', '')!
	} else if action == 'adopt' {
		p := s.adoption_profile(r.target_id)!
		name = p.name
		runtime_id = p.runtime_id
		revision = s.lifecycle_revision(p)!
		fingerprint = s.adoption_identity(p)!
	} else {
		p := s.lifecycle_profile(r.target_id)!
		name = p.name
		runtime_id = p.runtime_id
		revision = s.lifecycle_revision(p)!
		probe := json.decode[map[string]json.Any](s.lifecycle_probe(r, 'status', '')!)!
		fingerprint = probe['fingerprint']!.str()
	}
	report := McpLifecycleReport{ plan_id: new_remote_id()!, host_id: r.server.id, target_id: r.target_id, action: action, name: name, template: r.template, runtime_id: runtime_id, web_port: r.web_port, admin_port: r.admin_port, expires: time.now().unix() + 300, generation: r.generation }
	s.mcp_lifecycle_plan = McpLifecyclePlan{ request: r, report: report, revision: revision, fingerprint: fingerprint }
	s.state = ServerSnapshot{ ...s.state, mcp_lifecycle_preview: report }
	return json.encode(report)
}

fn (mut s ServerSession) lifecycle_validate_apply(r McpLifecycleRequest) ! {
	r.check()!
	p := s.mcp_lifecycle_plan
	if p.report.plan_id == '' || p.report.plan_id != r.plan_id || p.report.host_id != r.server.id || p.request.access != r.access || p.request.generation != r.generation || p.report.action != r.tool.all_before('_apply').all_after('instance_').replace('environment_', '') {
		return error('invalid_lifecycle_plan')
	}
	if p.operation_id != '' { return }
	if p.report.expires <= time.now().unix() || !s.state.connected || s.state.busy || s.server.id != r.server.id {
		return error('expired_or_disconnected_lifecycle_plan')
	}
	s.inspect()!
	if s.state.upgrades.any(!it.finished()) || s.state.deployments.any(!it.finished()) {
		return error('remote_operation_in_progress')
	}
	if p.report.action == 'create' {
		s.lifecycle_probe(p.request, 'create', '')!
	} else if p.report.action == 'adopt' {
		target := s.adoption_profile(p.request.target_id)!
		if s.lifecycle_revision(target)! != p.revision || s.adoption_identity(target)! != p.fingerprint {
			return error('discovered_environment_changed_since_preflight')
		}
	} else {
		target := s.lifecycle_profile(p.request.target_id)!
		if s.lifecycle_revision(target)! != p.revision {
			return error('instance_config_changed_since_preflight')
		}
		probe := json.decode[map[string]json.Any](s.lifecycle_probe(p.request, 'status', '')!)!
		if probe['fingerprint']!.str() != p.fingerprint {
			return error('process_changed_since_preflight')
		}
	}
	r.check()!
}

fn lifecycle_publish(w ServerWorker, state ServerSnapshot) {
	// Keep the newest accepted/completed state even when the UI has not consumed its previous snapshot.
	select {
		_ := <-w.snapshots {
		}
		else {
		}
	}
	select {
		w.snapshots <- state {
		}
		else {
		}
	}
}

fn (mut s ServerSession) lifecycle_set_operation(id string, phase string, target string, failure string) {
	for i, op in s.mcp_host_operations {
		if op.operation_id == id {
			s.mcp_host_operations[i] = McpHostOperation{ ...op, phase: phase, target_id: target, error: failure }
		}
	}
	s.state = ServerSnapshot{ ...s.state, mcp_host_operations: s.mcp_host_operations.clone() }
}

fn (mut s ServerSession) tick_mcp_connect() {
	r := s.mcp_connect_request
	if r.plan_id == '' { return }
	phase := if s.state.connected && s.state.server_id == r.server.id {
		'completed'
	} else if s.state.error {
		'failed'
	} else if s.state.host_key.id != '' {
		'awaiting_desktop_trust'
	} else {
		'connecting'
	}
	s.lifecycle_set_operation(r.plan_id, phase, '', if phase == 'failed' {
		'host_connection_failed_check_desktop'
	} else {
		''
	})
	if r.access.is_revoked() || r.access.selection().generation != r.generation {
		s.close()
		s.lifecycle_set_operation(r.plan_id, 'failed', '', 'binding_revoked')
		s.mcp_connect_request = McpLifecycleRequest{}
	} else if phase in ['completed', 'failed'] {
		s.mcp_connect_request = McpLifecycleRequest{}
	}
}

fn (mut s ServerSession) handle_mcp_lifecycle(r McpLifecycleRequest, w ServerWorker) {
	value := s.mcp_lifecycle_begin(r, w) or {
		r.reply <- DevelopmentReply{ error: true, value: err.msg() }
		return
	}
	lifecycle_publish(w, s.state)
	if value != '' { r.reply <- DevelopmentReply{ value: value } }
}

fn (mut s ServerSession) mcp_lifecycle_begin(r McpLifecycleRequest, w ServerWorker) !string {
	r.check()!
	if r.tool in ['host_register', 'host_disconnect', 'environment_discover'] {
		return s.mcp_registry_request(r)!
	}
	if r.tool.ends_with('_prepare') { return s.lifecycle_prepare(r)! }
	if r.tool == 'instance_status' {
		if !s.state.connected || s.server.id != r.server.id {
			return error('connect_registered_host_first')
		}
		s.inspect()!
		return s.lifecycle_probe(r, 'status', '')!
	}
	if r.tool == 'host_connect' {
		if s.state.busy { return error('host_worker_busy') }
		if s.state.connected {
			if s.server.id != r.server.id {
				return error('disconnect_current_host_in_desktop_first')
			}
			return json.encode({
				'phase':   'completed'
				'host_id': r.server.id
			})
		}
		if r.server.auth_method != 'key' {
			return error('desktop_password_authentication_required')
		}
		if s.mcp_host_operations.len >= 128 { return error('host_operation_capacity_reached') }
		id := new_remote_id()!
		s.connect(r.server, '')!
		s.mcp_connect_request = McpLifecycleRequest{ ...r, plan_id: id }
		s.mcp_host_operations << McpHostOperation{ operation_id: id, host_id: r.server.id, action: 'connect', phase: 'connecting', generation: r.generation }
		s.state = ServerSnapshot{ ...s.state, mcp_host_operations: s.mcp_host_operations.clone() }
		lifecycle_publish(w, s.state)
		return json.encode({
			'phase':        'accepted'
			'operation_id': id
		})
	}
	s.lifecycle_validate_apply(r)!
	if s.mcp_lifecycle_plan.operation_id != '' {
		return json.encode({
			'phase':        'accepted'
			'operation_id': s.mcp_lifecycle_plan.operation_id
		})
	}
	if s.mcp_host_operations.len >= 128 { return error('host_operation_capacity_reached') }
	id := new_remote_id()!
	s.mcp_lifecycle_plan.operation_id = id
	plan := s.mcp_lifecycle_plan
	s.mcp_host_operations << McpHostOperation{ operation_id: id, host_id: r.server.id, target_id: plan.report.target_id, action: plan.report.action, phase: 'running', generation: r.generation }
	s.state = ServerSnapshot{ ...s.state, busy: true, mcp_host_operations: s.mcp_host_operations.clone() }
	lifecycle_publish(w, s.state)
	r.reply <- DevelopmentReply{
		value: json.encode({
			'phase':        'accepted'
			'operation_id': id
		})
	}
	mut failure := ''
	mut target := plan.report.target_id
	match plan.report.action {
		'create' {
			s.create(ServerCommand{ name: plan.request.name, template: plan.request.template, runtime_id: plan.request.runtime_id, web_port: plan.request.web_port, admin_port: plan.request.admin_port }) or { failure = 'environment_creation_failed_check_desktop' }
			if failure == '' { target = s.state.created.id }
		}
		'adopt' {
			p := s.adoption_profile(target) or {
				failure = 'discovered_environment_missing'
				RemoteProfile{}
			}
			if failure == '' {
				profiles := load_remote_profiles() or {
					failure = 'environment_cache_read_failed'
					[]RemoteProfile{}
				}
				if failure == '' {
					save_remote_profiles(merge_discovered_profiles(profiles, [p])) or { failure = 'environment_cache_save_failed' }
				}
			}
		}
		'start' {
			s.start_project(ServerCommand{ project_id: target }) or { failure = 'instance_start_failed_check_desktop' }
		}
		'stop' {
			s.lifecycle_probe(plan.request, 'stop', plan.fingerprint) or { failure = 'instance_stop_incomplete_check_status' }
		}
		else { failure = 'invalid_lifecycle_action' }
	}
	s.state = ServerSnapshot{ ...s.state, busy: false }
	s.lifecycle_set_operation(id, if failure == '' { 'completed' } else { 'failed' }, target, failure)
	lifecycle_publish(w, s.state)
	// Reply was already sent before executing the remote mutation.
	return ''
}
