module host

import crypto.sha256
import json2 as json
import os
import runtime_upgrade
import time

pub struct McpPackageRequest {
pub:
	tool        string
	host_id     string
	tag         string
	platform    string
	download_id string
	package_id  string
	plan_id     string
	generation  u64
	deadline    i64
	access      &DevelopmentAccess = &DevelopmentAccess{}
	local       Worker
	reply       chan DevelopmentReply = chan DevelopmentReply{cap: 1}
}

pub struct McpPackagePreview {
pub:
	plan_id     string
	action      string
	host_id     string
	platform    string
	tag         string
	download_id string
	package_id  string
	expires     i64
	generation  u64
}

pub struct McpPackageOperation {
pub:
	operation_id     string
	action           string
	host_id          string
	phase            string
	download_id      string
	package_id       string
	error            string
	binding_revision u64
}

struct McpPackageArtifact {
	archive  string
	checksum string
	tag      string
	platform string
	access   &DevelopmentAccess = &DevelopmentAccess{}
	expires  i64
}

struct McpPackagePlan {
	request         McpPackageRequest
	preview         McpPackagePreview
	choice          RuntimeDownload
	artifact        McpPackageArtifact
	binary          string
	binary_hash     string
	config_revision string
mut:
	operation_id string
}

fn (r McpPackageRequest) check() ! {
	if r.deadline <= time.now().unix() || r.access.is_revoked() || r.access.selection().generation != r.generation {
		return error('stale_binding_revision: call context_get')
	}
}

fn (mut s ServerSession) clear_mcp_downloads() {
	for _, artifact in s.mcp_package_artifacts { os.rmdir_all(os.dir(artifact.archive)) or {} }
}

fn (r McpPackageRequest) probe(binary string, select_package bool) !string {
	selection := r.access.selection()
	call := DevelopmentCall{
		tool:       if select_package {
			'_runtime_package_select'
		} else {
			'runtime_package_probe'
		}
		binary:     binary
		arguments:  json.encode({
			'binding_revision': json.Any(r.generation)
			'package_id':       json.Any('sha256-' + sha256.hexhash(os.real_path(binary)))
		})
		access:     r.access
		generation: r.generation
		root:       selection.project.workdir
	}
	select {
		r.local.development <- call {
		}
		else {
			return error('local_worker_busy')
		}
	}
	// An accepted selection must retain its operation until the local owner replies.
	// Timing out here could report failure before a queued selection commits.
	response := <-call.reply
	if response.error { return error('runtime_package_validation_or_selection_failed') }
	body := json.decode[map[string]json.Any](response.value)!
	if !select_package && !(body['compatible'] or { json.Any(false) }).bool() {
		return error('runtime_package_incompatible')
	}
	return response.value
}

fn (mut s ServerSession) prepare_mcp_package(r McpPackageRequest) !string {
	r.check()!
	action := r.tool.all_before('_prepare').all_after('runtime_')
	mut platform := r.platform
	mut tag := r.tag
	mut choice := RuntimeDownload{}
	mut artifact := McpPackageArtifact{}
	mut binary := ''
	mut hash := ''
	mut revision := ''
	if action == 'download' {
		if platform !in ['macos-arm64', 'linux-amd64', 'linux-arm64'] || tag == '' {
			return error('explicit_official_tag_and_platform_required')
		}
		if s.mcp_package_artifacts.len >= 4 { return error('download_session_capacity_reached') }
		choice = resolve_runtime_download(platform, normalize_runtime_tag(tag)!, s.job)!
		tag = choice.tag
	} else if action == 'install' {
		artifact = s.mcp_package_artifacts[r.download_id] or { return error('unknown_download_id') }
		if artifact.access != r.access || artifact.expires <= time.now().unix() {
			return error('expired_or_foreign_download')
		}
		platform = artifact.platform
		tag = artifact.tag
		s.check_package_install_target(r.host_id, platform)!
		if sha256.sum(os.read_bytes(artifact.archive)!).hex() != artifact.checksum {
			return error('download_checksum_changed')
		}
	} else if action == 'package_select' {
		if r.host_id != '' { return error('remote_selection_requires_runtime_upgrade_prepare') }
		selected := r.access.selection()
		paths := r.access.runtime_package_paths(selected.binary)!
		binary = paths[r.package_id] or { return error('unknown_runtime_package') }
		r.probe(binary, false)!
		hash = sha256.sum(os.read_bytes(binary)!).hex()
		revision = runtime_upgrade.revision(selected.project.config_path)!
		platform = local_runtime_platform()
	} else {
		return error('unknown_package_action')
	}
	r.check()!
	preview := McpPackagePreview{ plan_id: new_remote_id()!, action: action, host_id: r.host_id, platform: platform, tag: tag, download_id: r.download_id, package_id: r.package_id, expires: time.now().unix() + 300, generation: r.generation }
	s.mcp_package_plan = McpPackagePlan{ request: r, preview: preview, choice: choice, artifact: artifact, binary: binary, binary_hash: hash, config_revision: revision }
	s.state = ServerSnapshot{ ...s.state, mcp_package_preview: preview }
	return json.encode(preview)
}

fn (s &ServerSession) check_package_install_target(host_id string, platform string) ! {
	if host_id == '' {
		if platform != local_runtime_platform() { return error('local_runtime_platform_mismatch') }
	} else if !s.state.connected || s.server.id != host_id || s.state.busy || s.state.platform != platform {
		return error('connected_matching_host_platform_required')
	}
}

fn (mut s ServerSession) handle_mcp_package(r McpPackageRequest, w ServerWorker) {
	value := s.begin_mcp_package(r, w) or {
		r.reply <- DevelopmentReply{ error: true, value: err.msg() }
		return
	}
	s.state = ServerSnapshot{ ...s.state, mcp_package_preview: s.mcp_package_plan.preview, mcp_package_operations: s.mcp_package_operations.clone() }
	lifecycle_publish(w, s.state)
	if value != '' { r.reply <- DevelopmentReply{ value: value } }
}

fn (mut s ServerSession) begin_mcp_package(r McpPackageRequest, w ServerWorker) !string {
	r.check()!
	if r.tool.ends_with('_prepare') { return s.prepare_mcp_package(r)! }
	plan := s.mcp_package_plan
	if plan.preview.plan_id == '' || plan.preview.plan_id != r.plan_id || plan.preview.generation != r.generation || plan.request.access != r.access || plan.preview.action != r.tool.all_before('_apply').all_after('runtime_') || plan.preview.host_id != r.host_id {
		return error('invalid_package_plan')
	}
	if plan.operation_id != '' {
		return json.encode({
			'phase':        'accepted'
			'operation_id': plan.operation_id
		})
	}
	if plan.preview.expires <= time.now().unix() || s.mcp_package_operations.len >= 128 {
		return error('expired_plan_or_operation_capacity')
	}
	if plan.preview.action == 'install' {
		s.check_package_install_target(r.host_id, plan.artifact.platform)!
	}
	if plan.preview.action == 'package_select' {
		if sha256.sum(os.read_bytes(plan.binary)!).hex() != plan.binary_hash || runtime_upgrade.revision(r.access.selection().project.config_path)! != plan.config_revision {
			return error('package_or_configuration_changed')
		}
	}
	r.check()!
	id := new_remote_id()!
	s.mcp_package_plan.operation_id = id
	s.mcp_package_operations << McpPackageOperation{ operation_id: id, action: plan.preview.action, host_id: r.host_id, phase: 'running', binding_revision: r.generation }
	s.state = ServerSnapshot{ ...s.state, busy: true, mcp_package_operations: s.mcp_package_operations.clone() }
	lifecycle_publish(w, s.state)
	r.reply <- DevelopmentReply{
		value: json.encode({
			'phase':        'accepted'
			'operation_id': id
		})
	}
	mut failure := ''
	mut download_id := ''
	mut package_id := ''
	if plan.preview.action == 'download' {
		artifact := s.perform_package_download(plan, r) or {
			failure = 'official_download_failed_check_desktop_network'
			McpPackageArtifact{}
		}
		if failure == '' {
			download_id = new_remote_id() or {
				failure = 'download_identity_failed'
				''
			}
			if failure == '' { s.mcp_package_artifacts[download_id] = artifact }
		}
	} else if plan.preview.action == 'install' {
		if sha256.sum(os.read_bytes(plan.artifact.archive) or { []u8{} }).hex() != plan.artifact.checksum {
			failure = 'download_checksum_changed'
		}
		if failure == '' {
			if r.host_id == '' {
				path := install_runtime_without_selection(plan.artifact.archive, plan.artifact.checksum, plan.artifact.tag, s.job) or {
					failure = 'local_package_install_failed'
					''
				}
				if failure == '' { package_id = 'sha256-' + sha256.hexhash(os.real_path(path)) }
			} else {
				s.install_release(plan.artifact.archive, plan.artifact.tag) or { failure = 'remote_package_install_failed' }
				if failure == '' { package_id = 'sha256-' + plan.artifact.checksum }
			}
		}
	} else {
		r.probe(plan.binary, true) or { failure = 'runtime_package_selection_failed_check_context' }
		if failure == '' { package_id = plan.preview.package_id }
	}
	mut result_generation := r.generation
	if failure == '' && plan.preview.action == 'package_select' {
		result_generation = r.access.selection().generation
		s.mcp_package_plan = McpPackagePlan{ ...s.mcp_package_plan, preview: McpPackagePreview{ ...plan.preview, generation: result_generation } }
	}
	s.mcp_package_operations[s.mcp_package_operations.len - 1] = McpPackageOperation{
		operation_id:     id
		action:           plan.preview.action
		host_id:          r.host_id
		phase:            if failure == '' {
			'completed'
		} else {
			'failed'
		}
		download_id:      download_id
		package_id:       package_id
		error:            failure
		binding_revision: result_generation
	}
	s.state = ServerSnapshot{ ...s.state, busy: false, mcp_package_preview: s.mcp_package_plan.preview, mcp_package_operations: s.mcp_package_operations.clone() }
	lifecycle_publish(w, s.state)
	return ''
}

fn (mut s ServerSession) perform_package_download(plan McpPackagePlan, r McpPackageRequest) !McpPackageArtifact {
	root := os.join_path(workbench_data_dir(), 'mcp-downloads')
	if os.is_link(root) { return error('unsafe_download_cache') }
	os.mkdir_all(root, mode: 0o700)!
	dir := os.join_path(root, new_remote_id()!)
	os.mkdir(dir, mode: 0o700)!
	mut keep := false
	defer { if !keep { os.rmdir_all(dir) or {} } }
	archive := download_runtime_files(plan.choice, dir, s.job)!
	expected := checksum_for(os.read_file(archive + '.sha256')!, plan.choice.archive.name)!
	if sha256.sum(os.read_bytes(archive)!).hex() != expected {
		return error('official_checksum_mismatch')
	}
	if r.access.is_revoked() || r.access.selection().generation != r.generation {
		return error('binding_revoked_during_download')
	}
	keep = true
	return McpPackageArtifact{ archive: archive, checksum: expected, tag: plan.choice.tag, platform: plan.choice.platform, access: r.access, expires: time.now().unix() + 3600 }
}

fn (mut d DevelopmentState) select_runtime_package(mut m Manager, call DevelopmentCall) !string {
	if !isnil(call.grant) || call.access.is_revoked() { return error('local_session_required') }
	selection := call.access.selection()
	if selection.generation != call.generation || selection.application.id == '' || m.project != selection.project {
		return error('stale_binding_revision')
	}
	if m.phase in [.starting, .running, .stopping] || (!isnil(m.process) && m.process.is_alive()) {
		return error('stop_local_runtime_before_package_selection')
	}
	probe := development_packages(m, DevelopmentCall{ ...call, tool: 'runtime_package_probe' }, DevelopmentArgs{ package_id: 'sha256-' + sha256.hexhash(os.real_path(call.binary)) })!
	result := json.decode[map[string]json.Any](probe)!
	if !(result['compatible'] or { json.Any(false) }).bool() {
		return error('runtime_package_incompatible')
	}
	if call.access.is_revoked() || call.access.selection().generation != selection.generation {
		return error('stale_binding_revision')
	}
	save_runtime_selection(call.binary)!
	d.previews.clear()
	mut access := call.access
	access.bind(selection.project, selection.application, call.binary, result['version']!.str())
	return json.encode({
		'binding_revision': access.selection().generation
	})
}
