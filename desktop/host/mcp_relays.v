module host

import encoding.base64
import os
import net.urllib
import json2 as json
import time

pub struct McpOrdinaryRelayRequest {
pub:
	tool                 string
	target_id            string
	hub_target_id        string
	connection_id        string
	source_connection_id string
	relay_id             string
	name                 string
	mode                 string
	port                 int
	path                 string = '/vhttpd/relay'
	verify_path          string
	route                string
	adapter_id           string
	resource_id          string
	updates              map[string]json.Any
	remove_fields []string
	edits []McpConfigEdit
	version_id string
	plan_id              string
	generation           u64
	deadline             i64
	access               &DevelopmentAccess = &DevelopmentAccess{}
	local                Worker
	reply                chan DevelopmentReply = chan DevelopmentReply{cap: 1}
}

pub struct McpRelayPreview {
pub:
	plan_id           string
	action            string
	target_id         string
	relay_id          string
	connection_id     string
	name              string
	adapter_id        string
	peer              string
	credential_source string
	route             string
	verify_path       string
	port              int
	restart_required  bool
	source            string
	sources []string
	removed_fields []string
	source_revision   string
	before            map[string]json.Any
	after             map[string]json.Any
	fields            []string
	preflight_required bool
	generation        u64
	expires           i64
}

pub struct McpRelayOperation {
pub:
	operation_id  string
	plan_id       string
	action        string
	target_id     string
	phase         string
	connection_id string
	error         string
	generation    u64
}

struct McpOrdinaryRelayPlan {
	owner              McpOrdinaryRelayRequest
	preview            McpRelayPreview
	entry              SharedRelay
	catalog_revision   string
	change             OrdinaryConfigChange
	changes []OrdinaryConfigChange
	root               string
	boot               string
	revision           string
	candidate_revision string
	history_id string
mut:
	operation_id string
	restored     bool
	applied      bool
	preflighted  bool
}

fn (r McpOrdinaryRelayRequest) check() ! {
	if r.access.is_revoked() || r.access.selection().generation != r.generation || r.deadline <= time.now().unix() {
		return error('stale_binding_revision: call context_get')
	}
}

fn (mut s ServerSession) ordinary_remote(id string) !(&RemoteManager, OrdinaryEndpoint) {
	if !s.state.connected || s.state.busy { return error('connect_registered_target_host_first') }
	targets := s.state.projects.filter(it.id == id && it.server_id == s.server.id)
	if targets.len != 1 { return error('unknown_registered_relay_target') }
	mut manager := &RemoteManager{}
	manager.connect_with_session(targets[0], '', s.state.control_path)!
	endpoint := OrdinaryEndpoint{ base: manager.proxy.target, token: targets[0].token, root: targets[0].config_path }
	return manager, endpoint
}

fn ordinary_close(mut manager RemoteManager) {
	manager.disconnect()
	for endpoint in manager.browser_endpoints {
		mut server := endpoint.server
		server.stop()
	}
}

fn (mut s ServerSession) ordinary_catalog(target string) !([]SharedRelay, string) {
	if target == '' {
		entries := load_shared_relays()!
		return entries, ordinary_catalog_revision(entries)
	}
	if !s.state.connected || !s.state.projects.any(it.id == target && it.server_id == s.server.id) {
		return error('connect_registered_catalog_host')
	}
	s.relay_catalog_operation(ServerCommand{ action: .relay_load, server: s.server })!
	return s.state.relay_catalog.entries, s.state.relay_catalog.revision
}

fn (mut s ServerSession) ordinary_connection(target string, id string) !SharedRelay {
	entries, _ := s.ordinary_catalog(target)!
	found := entries.filter(it.id == id)
	if found.len != 1 { return error('unknown_relay_connection') }
	return found[0]
}

fn (mut s ServerSession) ordinary_hub_reference(r McpOrdinaryRelayRequest) !SharedRelay {
	mut manager, endpoint := s.ordinary_remote(r.hub_target_id)!
	defer { ordinary_close(mut manager) }
	instance := ordinary_instance(endpoint)!
	workspace := ordinary_workspace(endpoint)!
	if ordinary_source_revision(workspace) != instance.disk_revision {
		return error('hub_source_not_effective')
	}
	plan := ordinary_runtime_plan(workspace)!
	descriptor := plan.relays[r.relay_id] or { return error('unknown_hub_relay_id') }
	if descriptor.mode != 'hub' || descriptor.options.strings['token'] == '' {
		return error('authenticated_hub_required')
	}
	ref := descriptor.ingress or { return error('hub_listener_required') }
	listener := plan.listeners[ref.id] or { return error('hub_listener_missing') }
	if listener.host !in ['0.0.0.0', '::'] {
		return error('hub_not_exposed_on_registered_host_use_saved_desktop_connection')
	}
	host_name := s.server.ssh_host
	if host_name.contains(':') { return error('configure_ipv6_relay_endpoint_in_desktop') }
	scheme := if listener.tls.enabled { 'wss' } else { 'ws' }
	path := descriptor.options.strings['path']
	entry := SharedRelay{
		id:       if r.connection_id == '' { new_shared_relay_id()! } else { r.connection_id }
		name:     r.name
		relay_id: r.relay_id
		url:      '${scheme}://${host_name}:${listener.port}${path}'
		token:    descriptor.options.strings['token']
	}
	entry.validate()!
	return entry
}

fn (mut s ServerSession) ordinary_prepare(r McpOrdinaryRelayRequest) !string {
	r.check()!
	if r.tool == 'relay_config_prepare' && r.mode !in ['hub', 'agent'] {
		return error('invalid_relay_configuration_mode')
	}
	if r.tool == 'relay_agent_control_prepare' && r.mode !in ['start', 'stop'] {
		return error('invalid_relay_control_action')
	}
	if s.mcp_relay_plans.len >= 64 { return error('relay_session_plan_capacity_reached') }
	action := if r.tool == 'shared_config_edit_prepare' { 'shared_edit' } else if r.tool == 'config_history_restore_prepare' { 'history_restore' } else if r.tool == 'relay_connection_save_prepare' {
		'catalog_save'
	} else if r.tool == 'relay_connection_delete_prepare' {
		'catalog_delete'
	} else {
		r.mode
	}
	mut entry := SharedRelay{}
	mut catalog_revision := ''
	mut change := OrdinaryConfigChange{}
	mut changes := []OrdinaryConfigChange{}
	mut root := ''
	mut boot := ''
	mut revision := ''
	mut candidate := ''
	mut route := r.route
	mut restart := false
	mut before := map[string]json.Any{}
	mut after := map[string]json.Any{}
	if action == 'catalog_save' && (r.name.trim_space() != r.name || r.name.bytes().any(it < 32 || it == 127)) {
		return error('invalid_relay_connection_name')
	}
	if action in ['catalog_save', 'catalog_delete'] {
		entries, current_revision := s.ordinary_catalog(r.target_id)!
		catalog_revision = current_revision
		if action == 'catalog_delete' {
			found := entries.filter(it.id == r.connection_id)
			if found.len != 1 { return error('unknown_relay_connection') }
			entry = found[0]
		} else {
			if r.source_connection_id != '' && r.hub_target_id != '' {
				return error('choose_one_relay_credential_reference')
			}
			if r.source_connection_id != '' {
				source := s.ordinary_connection('', r.source_connection_id)!
				entry = SharedRelay{ ...source, id: if r.connection_id == '' {
					new_shared_relay_id()!
				} else {
					r.connection_id
				}, name: r.name }
			} else {
				if r.hub_target_id == '' { return error('choose_relay_credential_reference') }
				entry = s.ordinary_hub_reference(r)!
			}
			entry.validate()!
			if r.connection_id != '' && !entries.any(it.id == r.connection_id) {
				return error('unknown_relay_connection_update')
			}
			if entries.any(it.name == entry.name && it.id != entry.id) {
				return error('relay_connection_name_conflict')
			}
		}
	} else {
		mut manager := &RemoteManager{}
		endpoint := if r.target_id == '' {
			r.local_endpoint(false)!
		} else {
			remote, ep := s.ordinary_remote(r.target_id)!
			manager = remote
			ep
		}
		defer { if r.target_id != '' { ordinary_close(mut manager) } }
		if r.target_id != '' { _ := s.lifecycle_profile(r.target_id)! }
		instance := ordinary_instance(endpoint)!
		workspace := ordinary_workspace(endpoint)!
		if ordinary_source_revision(workspace) != instance.disk_revision {
			return error('relay_source_not_effective')
		}
		if r.mode == 'agent' || (r.mode == 'edit' && r.connection_id != '') { entry = s.ordinary_connection(r.target_id, r.connection_id)! }
		if action in ['shared_edit', 'history_restore'] {
			if action == 'shared_edit' {
				next, previous, proposed := shared_build_changes(workspace, r.edits)!
				changes = next.clone(); before = previous.clone(); after = proposed.clone()
			} else {
				versions := s.config_history_versions(r, endpoint.root)!
				found := versions.filter(it.id == r.version_id)
				if found.len != 1 { return error('unknown_config_history_version') }
				changes = shared_history_changes(workspace, found[0].workspace)!
				before = {'source_revision': json.Any(instance.disk_revision), 'components': json.Any(shared_components(workspace)!.map(json.Any(it)))}
				after = {'source_revision': json.Any(found[0].revision), 'version_id': json.Any(r.version_id), 'components': json.Any(shared_components(found[0].workspace)!.map(json.Any(it)))}
				if json.encode(before).len + json.encode(after).len > 65536 { return error('config_history_preview_too_large_use_desktop') }
			}
			change = changes[0]
			_ := config_archive_save(s.config_history_identity(r, endpoint.root), workspace)!
		} else if r.mode == 'edit' {
			next, previous, proposed := relay_edit_change(r, workspace, entry)!
			changes = next.clone()
			change = next[0]
			before = previous.clone()
			after = proposed.clone()
		} else {
			next, selected_route := ordinary_build_config(r, workspace, entry)!
			change = next
			route = selected_route
		}
		root = endpoint.root
		boot = instance.boot_id
		revision = instance.disk_revision
		if changes.len == 0 { changes = [change] }
		candidate = ordinary_changed_revision(workspace, changes)
		restart = true
		if r.target_id != '' && !instance.manual_restart {
			return error('managed_manual_restart_required')
		}
		// The runtime preflights the entire draft before Desktop asks for confirmation.
		provisional := McpOrdinaryRelayPlan{ preview: McpRelayPreview{ plan_id: new_remote_id()! }, change: change }
		if r.mode != 'edit' && action !in ['shared_edit', 'history_restore'] { ordinary_draft(endpoint, provisional, false)! }
	}
	peer := if entry.url != '' {
		u := urllib.parse(entry.url)!
		u.host
	} else {
		''
	}
	credential_source := if r.source_connection_id != '' {
		'connection:' + r.source_connection_id
	} else if r.hub_target_id != '' {
		'environment:' + r.hub_target_id
	} else if r.connection_id != '' {
		'connection:' + r.connection_id
	} else {
		''
	}
	mut fields := r.updates.keys()
	fields << r.remove_fields.map('remove:' + it)
	mut removed := []string{}
	for key, _ in before { if key !in after { removed << key } }
	if (before['url_present'] or { json.Any(false) }).bool() && !(after['url_present'] or { json.Any(false) }).bool() { removed << 'url' }
	if (before['token_present'] or { json.Any(false) }).bool() && !(after['token_present'] or { json.Any(false) }).bool() { removed << 'token' }
	if r.mode == 'edit' && entry.id != '' { fields << 'credential_reference' }
	if action == 'shared_edit' { fields = before.keys() }
	if action == 'history_restore' { fields = ['history:' + r.version_id] }
	fields.sort()
	preview := McpRelayPreview{ plan_id: new_remote_id()!, action: action, target_id: r.target_id, relay_id: if entry.relay_id != '' {
		entry.relay_id
	} else {
		r.relay_id
	}, connection_id: entry.id, name: r.name, adapter_id: r.adapter_id, peer: peer, credential_source: credential_source, route: route, verify_path: r.verify_path, port: r.port, restart_required: restart, source: if root != '' { change.path.trim_string_left(os.dir(root) + '/') } else { '' }, sources: changes.map(it.path.trim_string_left(os.dir(root) + '/')), removed_fields: removed, source_revision: revision, before: before, after: after, fields: fields, preflight_required: r.mode == 'edit' || action in ['shared_edit', 'history_restore'], generation: r.generation, expires: time.now().unix() + 300 }
	plan := McpOrdinaryRelayPlan{ owner: r, preview: preview, entry: entry, catalog_revision: catalog_revision, change: change, changes: changes, root: root, boot: boot, revision: revision, candidate_revision: candidate, preflighted: r.mode != 'edit' && action !in ['shared_edit', 'history_restore'] }
	r.check()!
	s.mcp_relay_plans[preview.plan_id] = plan
	s.state = ServerSnapshot{ ...s.state, mcp_relay_preview: preview }
	return json.encode(preview)
}

pub fn ordinary_relay_apply_matches(tool string, action string) bool {
	if tool in ['shared_config_edit_preflight', 'shared_config_edit_apply', 'shared_config_edit_restore'] { return action == 'shared_edit' }
	if tool in ['config_history_restore_preflight', 'config_history_restore_apply', 'config_history_restore_undo'] { return action == 'history_restore' }
	if tool in ['relay_config_edit_preflight', 'relay_config_edit_apply', 'relay_config_edit_restore'] { return action == 'edit' }
	return (tool == 'relay_connection_save_apply' && action == 'catalog_save') || (tool == 'relay_connection_delete_apply' && action == 'catalog_delete') || (tool == 'relay_config_apply' && action in [
		'hub',
		'agent',
	]) || (tool == 'relay_agent_control_apply' && action in ['start', 'stop']) || (tool == 'relay_config_restore' && action in [
		'hub',
		'agent',
		'start',
		'stop',
	])
}

fn (mut s ServerSession) handle_ordinary_relay(r McpOrdinaryRelayRequest, w ServerWorker) {
	value := s.ordinary_request(r, w) or {
		r.reply <- DevelopmentReply{ error: true, value: ordinary_public_error(err.msg()) }
		return
	}
	s.state = ServerSnapshot{ ...s.state, mcp_relay_operations: s.mcp_relay_operations.clone(), mcp_relay_catalog_serial: s.mcp_relay_catalog_serial, mcp_relay_previews: s.mcp_relay_plans.values().map(it.preview) }
	lifecycle_publish(w, s.state)
	if value != '' { r.reply <- DevelopmentReply{ value: value } }
}

fn (mut s ServerSession) ordinary_request(r McpOrdinaryRelayRequest, w ServerWorker) !string {
	r.check()!
	if r.tool == 'config_history_list' { return s.config_history_list(r)! }
	if r.tool in ['shared_config_get', 'config_history_capture'] { return s.shared_config_query(r)! }
	if r.tool == 'relay_config_get' { return s.relay_edit_get(r)! }
	if r.tool in ['relay_database_resources_list', 'relay_database_probe'] { return s.ordinary_database(r)! }
	if r.tool.ends_with('_prepare') { return s.ordinary_prepare(r)! }
	if r.tool == 'relay_connection_probe' {
		connection := s.ordinary_connection(r.target_id, r.connection_id)!
		result := probe_shared_relay(connection)
		return json.encode({
			'ok':                     json.Any(result.ok)
			'stage':                  json.Any(result.stage)
			'message':                json.Any(result.message)
			'probe_origin':           json.Any('desktop')
			'temporary_probe_closed': json.Any(true)
		})
	}
	if r.tool == 'relay_runtime_status' {
		mut manager := &RemoteManager{}
		endpoint := if r.target_id == '' {
			r.local_endpoint(false)!
		} else {
			remote, ep := s.ordinary_remote(r.target_id)!
			manager = remote
			ep
		}
		defer { if r.target_id != '' { ordinary_close(mut manager) } }
		return ordinary_live(endpoint, r.relay_id)!
	}
	mut plan := s.mcp_relay_plans[r.plan_id] or { return error('unknown_ordinary_relay_plan') }
	if plan.owner.access != r.access || plan.owner.generation != r.generation || plan.owner.target_id != r.target_id || !ordinary_relay_apply_matches(r.tool, plan.preview.action) {
		return error('invalid_ordinary_relay_plan')
	}
	if r.tool in ['relay_config_edit_preflight', 'shared_config_edit_preflight', 'config_history_restore_preflight'] {
		if plan.applied || plan.restored || plan.preview.expires <= time.now().unix() { return error('relay_edit_prepare_again') }
		s.relay_edit_preflight(r, plan)!
		plan = McpOrdinaryRelayPlan{...plan, preflighted: true, preview: McpRelayPreview{...plan.preview, preflight_required: false}}
		s.mcp_relay_plans[r.plan_id] = plan
		return json.encode({'plan_id': json.Any(r.plan_id), 'phase': json.Any('prepared')})
	}
	restore := r.tool in ['relay_config_restore', 'relay_config_edit_restore', 'shared_config_edit_restore', 'config_history_restore_undo']
	if !restore && !plan.preflighted { return error('relay_edit_preflight_required') }
	if !restore && plan.restored { return error('relay_plan_restored_prepare_again') }
	if (!restore && plan.applied) || (restore && plan.restored) {
		return json.encode({
			'phase':        'accepted'
			'operation_id': plan.operation_id
		})
	}
	if restore && !plan.applied { return error('relay_apply_required_before_restore') }
	if !restore && plan.preview.expires <= time.now().unix() { return error('relay_plan_expired') }
	if s.mcp_relay_operations.len >= 128 { return error('relay_operation_capacity_reached') }
	id := new_remote_id()!
	plan.operation_id = id
	s.mcp_relay_plans[r.plan_id] = plan
	s.mcp_relay_operations << McpRelayOperation{ operation_id: id, plan_id: r.plan_id, action: if restore {
		'restore'
	} else {
		plan.preview.action
	}, target_id: r.target_id, phase: 'running', connection_id: plan.entry.id, generation: r.generation }
	s.state = ServerSnapshot{ ...s.state, busy: true, mcp_relay_operations: s.mcp_relay_operations.clone() }
	lifecycle_publish(w, s.state)
	r.reply <- DevelopmentReply{ value: json.encode({
		'phase':        'accepted'
		'operation_id': id
	}) }
	mut failure := ''
	s.ordinary_execute(r, mut plan, restore) or { failure = 'ordinary_relay_operation_failed_check_status_before_retry' }
	if failure == '' && plan.preview.action in ['shared_edit', 'history_restore'] {
		s.state = ServerSnapshot{...s.state, busy: false}
		s.shared_config_archive_effective(r) or { failure = 'configuration_effective_history_save_failed_check_status' }
	}
	if failure == '' {
		if restore { plan.restored = true } else { plan.applied = true }
	}
	s.mcp_relay_plans[r.plan_id] = plan
	s.mcp_relay_operations[s.mcp_relay_operations.len - 1] = McpRelayOperation{ operation_id: id, plan_id: r.plan_id, action: if restore {
		'restore'
	} else {
		plan.preview.action
	}, target_id: r.target_id, phase: if failure == '' { 'completed' } else { 'failed' }, connection_id: plan.entry.id, error: failure, generation: r.generation }
	s.state = ServerSnapshot{ ...s.state, busy: false, mcp_relay_operations: s.mcp_relay_operations.clone(), mcp_relay_catalog_serial: s.mcp_relay_catalog_serial, mcp_relay_previews: s.mcp_relay_plans.values().map(it.preview) }
	lifecycle_publish(w, s.state)
	return ''
}

fn (mut s ServerSession) ordinary_execute(r McpOrdinaryRelayRequest, mut plan McpOrdinaryRelayPlan, restore bool) ! {
	if !restore && plan.preview.action == 'edit' && plan.entry.id != '' && s.ordinary_connection(r.target_id, plan.entry.id)! != plan.entry {
		return error('relay_credential_reference_changed_since_preview')
	}
	if plan.preview.action in ['catalog_save', 'catalog_delete'] {
		entries, revision := s.ordinary_catalog(r.target_id)!
		if revision != plan.catalog_revision { return error('relay_catalog_changed') }
		r.check()!
		if r.target_id == '' {
			mut next := entries.filter(it.id != plan.entry.id)
			if plan.preview.action == 'catalog_save' { next << plan.entry }
			save_shared_relays(next)!
			s.mcp_relay_catalog_serial++
		} else {
			s.relay_catalog_operation(ServerCommand{ action: if plan.preview.action == 'catalog_save' {
				ServerAction.relay_save
			} else {
				ServerAction.relay_delete
			}, server: s.server, shared_relay: plan.entry, relay_revision: plan.catalog_revision })!
		}
		return
	}
	mut manager := &RemoteManager{}
	// Config writes target the original peer, independent of unrelated GUI selection.
	endpoint := if r.target_id == '' {
		r.local_endpoint(false) or {
			if !restore { return err }
			request := OrdinaryLocalRequest{ owner: r, restart: true, recoveries: ordinary_plan_changes(plan, true), expected_revision: plan.candidate_revision }
			r.local.ordinary_relay <- request
			result := <-request.reply
			if result.error { return error('local_offline_relay_recovery_failed') }
			if ordinary_instance(result.endpoint)!.disk_revision != plan.revision {
				return error('local_relay_recovery_revision_mismatch')
			}
			return
		}
	} else {
		// busy is our operation, not another operation.
		s.state = ServerSnapshot{ ...s.state, busy: false }
		remote, ep := s.ordinary_remote(r.target_id)!
		s.state = ServerSnapshot{ ...s.state, busy: true }
		manager = remote
		ep
	}
	defer { if r.target_id != '' { ordinary_close(mut manager) } }
	instance := ordinary_instance(endpoint) or {
		if restore && r.target_id != '' {
			s.ordinary_remote_recover(r, plan, endpoint)!
			return
		}
		return err
	}
	workspace := ordinary_workspace(endpoint)!
	expected := if restore { plan.candidate_revision } else { plan.revision }
	if instance.disk_revision != expected || ordinary_source_revision(workspace) != expected || (!restore && instance.boot_id != plan.boot) {
		return error('relay_configuration_changed_since_preflight')
	}
	for change in ordinary_plan_changes(plan, restore) {
		files := workspace.files.filter(it.source.path == change.path)
		if files.len != 1 || files[0].value != change.original { return error('relay_configuration_changed_since_preflight') }
	}
	draft := ordinary_draft(endpoint, plan, restore)!
	r.check()!
	ordinary_request(endpoint, .post, '/admin/config/changesets/' + draft + '/publish', '')!
	if !restore { plan.applied = true }
	next := json.decode[RemoteInstance](ordinary_request(endpoint, .get, '/admin/workbench/instance', '')!)!
	target_revision := if restore { plan.revision } else { plan.candidate_revision }
	if next.disk_revision != target_revision { return error('relay_published_revision_mismatch') }
	if r.target_id == '' {
		ep := r.local_endpoint(true)!
		final := ordinary_instance(ep)!
		if final.disk_revision != target_revision {
			return error('local_relay_restart_not_effective')
		}
	} else {
		target := s.state.projects.filter(it.id == r.target_id)[0]
		manager.snapshot = RemoteSnapshot{ profile_id: target.id, connected: true, instance: next }
		manager.restart()!
		until := time.ticks() + 90000
		mut ready := false
		for time.ticks() < until {
			time.sleep(150 * time.millisecond)
			manager.tick()
			final := manager.snapshot.instance
			if final.boot_id != next.boot_id && final.ready && final.disk_revision == target_revision && final.effective_revision == target_revision {
				ready = true
				break
			}
		}
		if !ready { return error('remote_relay_restart_pending') }
	}
}

fn (mut s ServerSession) ordinary_remote_recover(r McpOrdinaryRelayRequest, plan McpOrdinaryRelayPlan, endpoint OrdinaryEndpoint) ! {
	target := s.state.projects.filter(it.id == r.target_id)[0]
	if s.lifecycle_revision(target)! != plan.candidate_revision || target.config_path != plan.root { return error('remote_offline_recovery_conflict') }
	mut sources := map[string]string{}
	mut visiting := map[string]bool{}
	s.read_project_sources(target.config_path, mut sources, mut visiting)!
	changes := ordinary_plan_changes(plan, true)
	for change in changes {
		if !change.path.starts_with(os.dir(plan.root) + '/') || change.path !in sources || sources[change.path] != change.original { return error('remote_offline_recovery_conflict') }
		sources[change.path] = change.value
	}
	_ := remote_runtime_plan(target.config_path, sources)!
	payload := json.encode({'root': json.Any(os.dir(target.config_path)), 'changes': json.decode[json.Any](json.encode(changes))!})
	// Validate and stage every source before replacing any; ordinary failures
	// compensate already replaced files. As with Admin changesets this is not
	// crash recovery, and no user-controlled paths enter this private payload.
	script := "import json,base64,pathlib,os,tempfile,stat\np=json.loads(base64.b64decode('" + base64.encode_str(payload) + "'))\nroot=pathlib.Path(p['root']);staged=[];done=[]\ndef stage(f,v):\n fd,name=tempfile.mkstemp(prefix='.relay-restore-',dir=f.parent)\n with os.fdopen(fd,'wb') as out: out.write(v.encode());out.flush();os.fsync(out.fileno())\n os.chmod(name,stat.S_IMODE(f.stat().st_mode))\n return name\ndef check(c):\n f=pathlib.Path(c['path']);assert root in f.parents and f.resolve()==f and not f.is_symlink() and f.is_file()\n assert f.read_bytes()==c['original'].encode()\n return f\ntry:\n for c in p['changes']:\n  f=check(c);staged.append((c,stage(f,c['value'])))\n for c,name in staged: check(c)\n for c,name in staged:\n  f=check(c);os.replace(name,f);done.append(c)\nexcept BaseException:\n for c in reversed(done):\n  f=pathlib.Path(c['path']);assert not f.is_symlink() and f.read_bytes()==c['value'].encode()\n  os.replace(stage(f,c['original']),f)\n raise\nfinally:\n for c,name in staged:\n  if os.path.exists(name):os.unlink(name)\n"
	r.check()!
	s.shell('python3 -c ' + shell_quote(script), 10000)!
	s.start_project(ServerCommand{ project_id: target.id })!
	until := time.ticks() + 90000
	for time.ticks() < until {
		if final := ordinary_instance(endpoint) {
			if final.disk_revision == plan.revision { return }
		}
		time.sleep(200 * time.millisecond)
	}
	return error('remote_relay_recovery_not_ready')
}

fn ordinary_public_error(message string) string {
	if message.len < 96 && message.bytes().all((it >= u8(`a`) && it <= u8(`z`)) || it.is_digit() || it == `_`) {
		return message
	}
	if message == 'stale_binding_revision: call context_get' { return message }
	return 'ordinary_relay_preflight_failed_check_source_and_runtime'
}

fn (mut s ServerSession) shared_config_archive_effective(r McpOrdinaryRelayRequest) ! {
	mut manager := &RemoteManager{}
	endpoint := if r.target_id == '' { r.local_endpoint(false)! } else { remote, ep := s.ordinary_remote(r.target_id)!; manager = remote; ep }
	defer { if r.target_id != '' { ordinary_close(mut manager) } }
	instance := ordinary_instance(endpoint)!
	workspace := ordinary_workspace(endpoint)!
	if instance.disk_revision != ordinary_source_revision(workspace) { return error('configuration_history_source_not_effective') }
	_ := config_archive_save(s.config_history_identity(r, endpoint.root), workspace)!
}
