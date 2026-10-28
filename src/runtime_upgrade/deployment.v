module runtime_upgrade

import app_bundle
import config
import crypto.sha256
import json2 as json
import os
import process_runtime

pub struct DeploymentRequest {
pub:
	id                string
	server_root       string
	config_path       string
	runtime_id        string
	admin_port        int
	token             string
	expected_boot     string
	expected_revision string
	payload_hash      string
}

pub struct DeploymentStatus {
pub:
	id               string
	config_path      string
	phase            string
	error            string
	revision         string
	boot_id          string
	previous_release string
}

pub fn (s DeploymentStatus) finished() bool {
	return s.phase in ['completed', 'rolled_back', 'failed', 'rollback_failed']
}

pub struct DeploymentPreview {
pub:
	id          string
	config_path string
	files       []app_bundle.FileView
	preserved   []string
	revision    string
}

struct DeploymentFile {
	path          string
	before_exists bool
	before_hash   string
	before_mode   int
	after_hash    string
	after_mode    int
}

struct ApplicationManifest {
	id    string
	files []DeploymentFile
}

struct DeploymentPlan {
	preview           DeploymentPreview
	files             []DeploymentFile
	configs           []string
	previous_manifest string
}

fn (r DeploymentRequest) runtime_request(rev string) Request {
	return Request{ id: r.id, server_root: r.server_root, config_path: r.config_path, previous_id: r.runtime_id, target_id: r.runtime_id, admin_port: r.admin_port, token: r.token, expected_boot: r.expected_boot, expected_revision: rev }
}

fn deployment_paths(path string) !(DeploymentRequest, string, string) {
	if os.is_link(path) || os.file_size(path) > 65536 || os.stat(path)!.mode & 0o077 != 0 {
		return error('unsafe_deployment_request')
	}
	r := json.decode[DeploymentRequest](os.read_file(path)!)!
	project := os.dir(r.config_path)
	dir := os.dir(path)
	if !valid_id(r.id) || !runtime_id(r.runtime_id) || r.payload_hash.len != 64 || r.expected_revision.len != 64 || r.expected_boot == '' || r.token == '' || r.token.contains('\n') || r.admin_port < 1 || r.admin_port > 65535 {
		return error('invalid_deployment_request')
	}
	if os.real_path(r.server_root) != r.server_root || r.config_path != os.join_path(r.server_root, 'instances', os.file_name(project), 'vhttpd.toml') || dir != os.join_path(project, '.desktop-deployments', r.id) {
		return error('unmanaged_instance')
	}
	for p in [r.server_root, os.join_path(r.server_root, 'instances'), project, r.config_path,
		os.join_path(project, '.desktop-deployments'), dir, binary(r.server_root, r.runtime_id)] {
		if os.is_link(p) || !os.exists(p) { return error('unsafe_deployment_path') }
	}
	if os.real_path(os.executable()) != binary(r.server_root, r.runtime_id) {
		return error('runtime_binding_changed')
	}
	return r, project, dir
}

fn deployment_sources(root string, p app_bundle.Payload) !map[string]string {
	mut out := map[string]string{}
	for rel in p.configs {
		out[os.join_path(root, rel)] = os.read_file(app_bundle.safe_target(root, rel)!)!
	}
	return out
}

fn deployment_revision(overrides map[string]string) string {
	mut entries := []string{}
	for path, value in overrides { entries << path + ':' + sha256.hexhash(value) }
	entries.sort()
	return sha256.hexhash(entries.join('\n'))
}

fn deployment_file(root string, relative string) !DeploymentFile {
	path := app_bundle.safe_target(root, relative)!
	if !os.exists(path) { return DeploymentFile{ path: relative } }
	if !os.is_file(path) || os.file_size(path) > 16 * 1024 * 1024 {
		return error('deployment_file_conflict')
	}
	return DeploymentFile{ path: relative, before_exists: true, before_hash: sha256.sum(os.read_bytes(path)!).hex(), before_mode: int(os.stat(path)!.mode & 0o777) }
}

fn verify_deployment_inputs(project string, files []DeploymentFile) ! {
	for file in files {
		now := deployment_file(project, file.path)!
		if now.before_exists != file.before_exists || now.before_hash != file.before_hash || now.before_mode != file.before_mode {
			return error('deployment_preview_stale')
		}
	}
}

fn read_application_manifest(project string) !string {
	path := os.join_path(project, '.desktop-application.json')
	if !os.exists(path) { return '' }
	if os.is_link(path) || os.file_size(path) > 2097152 {
		return error('unsafe_application_manifest')
	}
	text := os.read_file(path)!
	manifest := json.decode[ApplicationManifest](text)!
	if !valid_id(manifest.id) || manifest.files.len > app_bundle.max_files {
		return error('unsafe_application_manifest')
	}
	for file in manifest.files {
		if !app_bundle.safe_path(file.path) { return error('unsafe_application_manifest') }
	}
	return text
}

fn deployment_status(dir string, r DeploymentRequest, phase string, reason string, instance Instance, previous string) ! {
	private_write(os.join_path(dir, 'status.json'), json.encode(DeploymentStatus{ id: r.id, config_path: r.config_path, phase: phase, error: deployment_safe_error(reason), revision: instance.effective_revision, boot_id: instance.boot_id, previous_release: previous }))!
}

// Preparation has no live-file writes and does not stop the instance.
pub fn prepare_deployment(path string) !DeploymentPreview {
	r, project, dir := deployment_paths(path)!
	defer { os.rm(path) or {} }
	old := find_instance(r.runtime_request(r.expected_revision))!
	// Preserve the running instance's variable environment, never the Mac's.
	for key, value in old.environment { os.setenv(key, value, true) }
	current := probe(r.runtime_request(r.expected_revision))!
	if !current.ready || current.boot_id != r.expected_boot || current.disk_revision != r.expected_revision || current.effective_revision != r.expected_revision {
		return error('instance_not_effective')
	}
	raw_path := os.join_path(dir, 'payload.json')
	if os.is_link(raw_path) || os.file_size(raw_path) > 96 * 1024 * 1024 {
		return error('invalid_application_bundle')
	}
	raw := os.read_file(raw_path)!
	if sha256.hexhash(raw) != r.payload_hash { return error('bundle_checksum_mismatch') }
	payload := json.decode[app_bundle.Payload](raw)!
	payload.validate()!
	app_bundle.check_portable(payload)!
	if payload.id != r.id { return error('invalid_application_bundle') }
	candidate := os.join_path(dir, 'candidate')
	if os.exists(candidate) { return error('deployment_preview_exists') }
	os.mkdir(candidate, mode: 0o700)!
	app_bundle.materialize(payload, candidate)!
	preserved := app_bundle.preserve_remote(candidate, payload, r.config_path)!
	stage_sources := deployment_sources(candidate, payload)!
	mut target_sources := map[string]string{}
	for source, value in stage_sources {
		target_sources[os.join_path(project, source[candidate.len + 1..])] = value
	}
	config.load_runtime_plan_with_overrides(r.config_path, target_sources) or { return error('whole_project_validation_failed') }
	config.load_runtime_plan_file(os.join_path(candidate, 'vhttpd.toml')) or { return error('whole_project_validation_failed') }
	previous_manifest := read_application_manifest(project)!
	mut paths := payload.files.map(it.path)
	if previous_manifest != '' {
		previous := json.decode[ApplicationManifest](previous_manifest)!
		for file in previous.files { if file.path !in paths { paths << file.path } }
	}
	mut files := []DeploymentFile{}
	mut views := []app_bundle.FileView{}
	for relative in paths {
		before := deployment_file(project, relative)!
		matches := payload.files.filter(it.path == relative)
		after_hash := if matches.len > 0 {
			sha256.sum(os.read_bytes(app_bundle.safe_target(candidate, relative)!)!).hex()
		} else {
			''
		}
		file := DeploymentFile{ ...before, after_hash: after_hash, after_mode: if matches.len > 0 {
			matches[0].mode
		} else {
			0
		} }
		files << file
		views << app_bundle.FileView{ path: relative, action: if after_hash == '' {
			'delete'
		} else if !before.before_exists {
			'add'
		} else if before.before_hash == after_hash {
			'unchanged'
		} else {
			'replace'
		}, size: if after_hash == '' {
			0
		} else {
			int(os.file_size(os.join_path(candidate, relative)))
		} }
		if before.before_exists {
			backup := app_bundle.safe_target(os.join_path(dir, 'previous'), relative)!
			os.mkdir_all(os.dir(backup), mode: 0o700)!
			bytes := os.read_bytes(os.join_path(project, relative))!
			if sha256.sum(bytes).hex() != before.before_hash {
				return error('deployment_preview_stale')
			}
			os.write_file_array(backup, bytes)!
			os.chmod(backup, 0o600)!
		}
	}
	preview := DeploymentPreview{ id: r.id, config_path: r.config_path, files: views, preserved: preserved, revision: deployment_revision(target_sources) }
	private_write(os.join_path(dir, 'plan.json'), json.encode(DeploymentPlan{ preview: preview, files: files, configs: payload.configs, previous_manifest: previous_manifest }))!
	private_write(os.join_path(dir, 'preview.json'), json.encode(preview))!
	return preview
}

fn write_deployment_files(project string, dir string, files []DeploymentFile, restore bool) ! {
	for file in files {
		target := app_bundle.safe_target(project, file.path)!
		exists := if restore { file.before_exists } else { file.after_hash != '' }
		if !exists {
			if os.exists(target) { os.rm(target)! }
			continue
		}
		source := app_bundle.safe_target(os.join_path(dir, if restore {
			'previous'
		} else {
			'candidate'
		}), file.path)!
		bytes := os.read_bytes(source)!
		expected := if restore { file.before_hash } else { file.after_hash }
		if sha256.sum(bytes).hex() != expected { return error('deployment_snapshot_changed') }
		os.mkdir_all(os.dir(target), mode: 0o700)!
		// Service is stopped. No reader can observe a partially applied project.
		temp := target + '.deployment-write'
		if os.exists(temp) || os.is_link(temp) { return error('deployment_write_conflict') }
		mut output := os.open_file(temp, 'wx', 0o600)!
		defer { os.rm(temp) or {} }
		count := output.write(bytes) or {
			output.close()
			return err
		}
		output.close()
		if count != bytes.len { return error('deployment_write_failed') }
		os.chmod(temp, if restore { file.before_mode } else { file.after_mode })!
		os.mv(temp, target)!
	}
}

fn check_deployed_files(project string, files []DeploymentFile) ! {
	for file in files {
		path := app_bundle.safe_target(project, file.path)!
		if file.after_hash == '' {
			if os.exists(path) { return error('application_changed_during_deployment') }
			continue
		}
		if !os.is_file(path) || sha256.sum(os.read_bytes(path)!).hex() != file.after_hash {
			return error('application_changed_during_deployment')
		}
	}
}

fn deployment_restore(dir string, r DeploymentRequest, plan DeploymentPlan, old Identity, target Identity, reason string) ! {
	deployment_status(dir, r, 'rolling_back', reason, Instance{}, '') or {}
	if target.pid > 0 && target.alive() {
		stop(target) or {
			deployment_status(dir, r, 'rollback_failed', 'target_process_still_alive', Instance{}, '')!
			return
		}
	}
	// Reject outside edits instead of overwriting new user data during recovery.
	for file in plan.files {
		now := deployment_file(os.dir(r.config_path), file.path)!
		if now.before_exists && now.before_hash != file.after_hash && now.before_hash != file.before_hash {
			return error('application_changed_during_deployment')
		}
	}
	write_deployment_files(os.dir(r.config_path), dir, plan.files, true)!
	marker := os.join_path(os.dir(r.config_path), '.desktop-application.json')
	if plan.previous_manifest == '' {
		if os.exists(marker) { os.rm(marker)! }
	} else {
		private_write(marker, plan.previous_manifest)!
	}
	if revision(r.config_path)! != r.expected_revision {
		return error('project_changed_during_deployment')
	}
	restored := launch(old.executable, old)!
	instance := wait_ready(r.runtime_request(r.expected_revision), restored, '')!
	deployment_status(dir, r, 'rolled_back', reason, instance, '')!
}

pub fn run_deployment(path string) ! {
	$if !linux {
		return error('deployment_platform_unsupported')
	}
	r, project, dir := deployment_paths(path)!
	lock_dir := os.join_path(project, '.desktop-runtime-lock')
	if os.read_file(os.join_path(lock_dir, 'owner'))! != r.id {
		return error('deployment_lock_missing')
	}
	defer {
		for file in ['request.json', 'plan.json', 'payload.json'] {
			os.rm(os.join_path(dir, file)) or {}
		}
		os.rm(os.join_path(lock_dir, 'owner')) or {}
		os.rmdir(lock_dir) or {}
	}
	process_runtime.detach_restart_helper(os.join_path(dir, 'runtime.log'))!
	plan_text := os.read_file(os.join_path(dir, 'plan.json')) or {
		deployment_status(dir, r, 'failed', 'invalid_deployment_plan', Instance{}, '')!
		return
	}
	plan := json.decode[DeploymentPlan](plan_text) or {
		deployment_status(dir, r, 'failed', 'invalid_deployment_plan', Instance{}, '')!
		return
	}
	mut old := Identity{}
	mut target := Identity{}
	mut stopped := []bool{}
	deployment_status(dir, r, 'validating', '', Instance{}, '')!
	deployment_perform(dir, r, plan, mut old, mut target, mut stopped) or {
		reason := deployment_safe_error(err.msg())
		if stopped.len > 0 && stopped[0] {
			deployment_restore(dir, r, plan, old, target, reason) or { deployment_status(dir, r, 'rollback_failed', err.msg(), Instance{}, '')! }
		} else {
			deployment_status(dir, r, 'failed', reason, Instance{}, '')!
		}
	}
}

fn deployment_perform(dir string, r DeploymentRequest, plan DeploymentPlan, mut old Identity, mut target Identity, mut stopped []bool) ! {
	if plan.preview.id != r.id || plan.preview.config_path != r.config_path || plan.preview.revision.len != 64 {
		return error('invalid_deployment_plan')
	}
	verify_deployment_inputs(os.dir(r.config_path), plan.files)!
	if read_application_manifest(os.dir(r.config_path))! != plan.previous_manifest {
		return error('deployment_preview_stale')
	}
	instance := probe(r.runtime_request(r.expected_revision))!
	if !instance.ready || instance.boot_id != r.expected_boot || instance.disk_revision != r.expected_revision || instance.effective_revision != r.expected_revision {
		return error('instance_not_effective')
	}
	old = find_instance(r.runtime_request(r.expected_revision))!
	for key, value in old.environment { os.setenv(key, value, true) }
	for file in plan.files {
		if file.after_hash != '' {
			if sha256.sum(os.read_bytes(app_bundle.safe_target(os.join_path(dir, 'candidate'), file.path)!)!).hex() != file.after_hash {
				return error('deployment_snapshot_changed')
			}
		}
		if file.before_exists {
			if sha256.sum(os.read_bytes(app_bundle.safe_target(os.join_path(dir, 'previous'), file.path)!)!).hex() != file.before_hash {
				return error('deployment_snapshot_changed')
			}
		}
	}
	mut overrides := map[string]string{}
	for rel in plan.configs {
		overrides[app_bundle.safe_target(os.dir(r.config_path), rel)!] = os.read_file(app_bundle.safe_target(os.join_path(dir, 'candidate'), rel)!)!
	}
	config.load_runtime_plan_with_overrides(r.config_path, overrides) or { return error('whole_project_validation_failed') }
	if deployment_revision(overrides) != plan.preview.revision {
		return error('deployment_snapshot_changed')
	}
	deployment_status(dir, r, 'stopping', '', Instance{}, '')!
	stop(old)!
	stopped << true
	deployment_status(dir, r, 'switching', '', Instance{}, '')!
	write_deployment_files(os.dir(r.config_path), dir, plan.files, false)!
	if revision(r.config_path)! != plan.preview.revision {
		return error('whole_project_validation_failed')
	}
	config.load_runtime_plan_file(r.config_path) or { return error('whole_project_validation_failed') }
	deployment_status(dir, r, 'starting', '', Instance{}, '')!
	target = launch(old.executable, old)!
	effective := wait_ready(r.runtime_request(plan.preview.revision), target, '')!
	check_deployed_files(os.dir(r.config_path), plan.files)!
	private_write(os.join_path(os.dir(r.config_path), '.desktop-application.json'), json.encode(ApplicationManifest{ id: r.id, files: plan.files.filter(it.after_hash != '') }))!
	deployment_status(dir, r, 'completed', '', effective, '')!
}

pub fn deployment_safe_error(reason string) string {
	if reason == '' { return '' }
	if reason in ['bundle_checksum_mismatch', 'invalid_application_bundle', 'listener_mapping_required',
		'remote_credential_required', 'whole_project_validation_failed', 'instance_not_effective',
		'deployment_preview_stale', 'application_changed_during_deployment',
		'project_changed_during_deployment', 'deployment_snapshot_changed', 'deployment_file_conflict',
		'target_process_still_alive', 'new_process_exited', 'startup_or_effectiveness_timeout',
		'process_identity_unavailable', 'old_process_still_alive', 'runtime_binding_changed'] {
		return reason
	}
	return 'application_deployment_failed'
}
