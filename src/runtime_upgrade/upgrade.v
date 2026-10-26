module runtime_upgrade

import config
import crypto.sha256
import json2 as json
import net.http
import os
import process_runtime
import time

pub struct Request {
pub:
	id                string
	server_root       string
	config_path       string
	previous_id       string
	target_id         string
	previous_version  string
	target_version    string
	admin_port        int
	token             string
	expected_boot     string
	expected_revision string
}

pub struct Status {
pub:
	id          string
	config_path string
	previous_id string
	target_id   string
	phase       string
	error       string
	version     string
	boot_id     string
	revision    string
}

pub fn (s Status) finished() bool {
	return s.phase in ['completed', 'rolled_back', 'failed', 'rollback_failed']
}

pub struct Check {
pub:
	protocol int
	revision string
	version  string
}

pub fn revision(path string) !string {
	sources := config.runtime_config_sources(path)!
	mut entries := []string{}
	for source in sources {
		entries << source.path + ':' + sha256.hexhash(os.read_file(source.path)!)
	}
	entries.sort()
	return sha256.hexhash(entries.join('\n'))
}

pub fn check(path string, version string) !Check {
	config.load_runtime_plan_file(path) or { return error('whole_project_validation_failed') }
	return Check{ protocol: 1, revision: revision(path)!, version: version }
}

fn valid_id(id string) bool { return id.len == 24 && id.bytes().all(it.is_hex_digit()) }

fn runtime_id(id string) bool {
	return id == 'legacy' || (id.len == 71 && id.starts_with('sha256-') && id[7..].bytes().all(it.is_hex_digit()))
}

fn binary(root string, id string) string {
	return os.join_path(root, if id == 'legacy' { 'runtime' } else { 'runtimes/' + id }, 'vhttpd')
}

pub fn (r Request) validate() ! {
	if !valid_id(r.id) || !runtime_id(r.previous_id) || !runtime_id(r.target_id) || r.previous_id == r.target_id {
		return error('invalid_upgrade_request')
	}
	if !r.server_root.starts_with('/') || os.real_path(r.server_root) != r.server_root || r.config_path != os.join_path(r.server_root, 'instances', os.file_name(os.dir(r.config_path)), 'vhttpd.toml') {
		return error('unmanaged_instance')
	}
	if r.token == '' || r.token.contains('\n') || r.admin_port < 1 || r.admin_port > 65535 || r.expected_boot == '' || r.expected_revision.len != 64 {
		return error('invalid_upgrade_request')
	}
	for path in [os.dir(r.config_path), r.config_path, binary(r.server_root, r.previous_id),
		binary(r.server_root, r.target_id)] {
		if os.is_link(path) || !os.exists(path) { return error('unsafe_upgrade_path') }
	}
}

fn private_write(path string, text string) ! {
	if os.is_link(path) { return error('unsafe_upgrade_path') }
	temp := path + '.tmp'
	if os.exists(temp) { return error('upgrade_write_conflict') }
	mut file := os.open_file(temp, 'wx', 0o600)!
	defer { os.rm(temp) or {} }
	file.write_string(text) or {
		file.close()
		return err
	}
	file.close()
	os.mv(temp, path)!
}

struct Instance {
	config_path        string
	ready              bool
	boot_id            string
	effective_revision string
	disk_revision      string
	manual_restart     bool
	version            string
	error              string
}

fn probe(r Request) !Instance {
	mut request := http.Request{ url: 'http://127.0.0.1:${r.admin_port}/admin/workbench/instance', read_timeout: 2 * time.second }
	request.add_custom_header('x-vhttpd-admin-token', r.token)!
	response := request.do()!
	if response.status_code != 200 { return error('admin_unavailable') }
	instance := json.decode[Instance](response.body)!
	if instance.config_path != r.config_path { return error('instance_changed') }
	return instance
}

struct Identity {
	pid         int
	start       string
	executable  string
	args        []string
	cwd         string
	environment map[string]string
}

fn start_time(pid int) !string {
	fields := os.read_file('/proc/${pid}/stat')!.all_after_last(') ').fields()
	if fields.len < 20 { return error('process_identity_unavailable') }
	return fields[19]
}

fn (p Identity) alive() bool {
	return (start_time(p.pid) or { '' }) == p.start && (os.readlink('/proc/${p.pid}/exe') or { '' }) == p.executable
}

fn find_instance(r Request) !Identity {
	mut matches := []Identity{}
	expected := binary(r.server_root, r.previous_id)
	for name in os.ls('/proc')! {
		if !name.bytes().all(it.is_digit()) { continue }
		pid := name.int()
		if (os.stat('/proc/${pid}') or { continue }).uid != u32(os.getuid()) { continue }
		if (os.readlink('/proc/${pid}/exe') or { continue }) != expected { continue }
		args := (os.read_file('/proc/${pid}/cmdline') or { continue }).split('\x00').filter(it != '')
		if args.len < 2 || '--manual-restart' !in args { continue }
		if config.source_config_path(args[1..]) != r.config_path { continue }
		mut env := map[string]string{}
		for item in (os.read_file('/proc/${pid}/environ') or { continue }).split('\x00') {
			if item.contains('=') { env[item.all_before('=')] = item.all_after('=') }
		}
		env.delete('VHTTPD_RESTART_OPERATION')
		matches << Identity{ pid: pid, start: start_time(pid)!, executable: expected, args: args[1..], cwd: os.readlink('/proc/${pid}/cwd')!, environment: env }
	}
	if matches.len != 1 { return error('process_identity_ambiguous') }
	return matches[0]
}

fn stop(p Identity) ! {
	if !p.alive() { return error('process_identity_changed') }
	// Verify the live start time and executable before signalling; never use a saved PID alone.
	signal_checked(p)!
	until := time.ticks() + 30000
	for p.alive() && time.ticks() < until { time.sleep(100 * time.millisecond) }
	if p.alive() { return error('old_process_still_alive') }
}

fn launch(executable string, original Identity) !Identity {
	mut child := os.new_process(executable)
	child.set_args(original.args)
	child.set_work_folder(original.cwd)
	child.set_environment(original.environment)
	child.run()
	if child.pid <= 0 { return error('new_process_exited') }
	// fork() returns before exec(): the child can still expose the helper's
	// executable briefly, especially when rolling back to a different package.
	until := time.ticks() + 5000
	for time.ticks() < until {
		if !child.is_alive() {
			child.wait()
			child.close()
			return error('new_process_exited')
		}
		started := start_time(child.pid) or { '' }
		if started != '' && (os.readlink('/proc/${child.pid}/exe') or { '' }) == executable {
			p := Identity{ ...original, pid: child.pid, start: started, executable: executable }
			child.close()
			return p
		}
		time.sleep(25 * time.millisecond)
	}
	child.signal_term()
	child.wait()
	child.close()
	return error('new_process_exited')
}

fn wait_ready(r Request, p Identity, expected_version string) !Instance {
	until := time.ticks() + 90000
	for time.ticks() < until {
		if !p.alive() { return error('new_process_exited') }
		if instance := probe(r) {
			if instance.error in ['executor_warmup_failed', 'whole_project_invalid'] {
				return error('startup_or_effectiveness_timeout')
			}
			if instance.ready && instance.boot_id != r.expected_boot && instance.disk_revision == r.expected_revision && instance.effective_revision == r.expected_revision {
				if expected_version != '' && instance.version != expected_version {
					return error('runtime_version_mismatch')
				}
				return instance
			}
		}
		time.sleep(200 * time.millisecond)
	}
	return error('startup_or_effectiveness_timeout')
}

fn save_status(dir string, r Request, phase string, reason string, instance Instance) ! {
	private_write(os.join_path(dir, 'status.json'), json.encode(Status{ id: r.id, config_path: r.config_path, previous_id: r.previous_id, target_id: r.target_id, phase: phase, error: reason, version: instance.version, boot_id: instance.boot_id, revision: instance.effective_revision }))!
}

// Runs on the server, detached from SSH. Desktop disconnect/exit cannot cancel recovery.
pub fn run(path string) ! {
	$if !linux {
		return error('upgrade_platform_unsupported')
	}
	if os.is_link(path) || os.file_size(path) > 65536 { return error('unsafe_upgrade_request') }
	r := json.decode[Request](os.read_file(path)!)!
	r.validate()!
	dir := os.dir(path)
	project := os.dir(r.config_path)
	if dir != os.join_path(project, '.desktop-upgrades', r.id) || os.read_file(os.join_path(project, '.desktop-runtime-lock', 'owner'))! != r.id {
		return error('upgrade_lock_missing')
	}
	if os.real_path(os.executable()) != binary(r.server_root, r.target_id) {
		return error('target_executable_changed')
	}
	defer {
		os.rm(path) or {}
		os.rm(os.join_path(project, '.desktop-runtime-lock', 'owner')) or {}
		os.rmdir(os.join_path(project, '.desktop-runtime-lock')) or {}
	}
	process_runtime.detach_restart_helper(os.join_path(dir, 'runtime.log'))!
	save_status(dir, r, 'validating', '', Instance{})!
	perform(dir, r) or {
		save_status(dir, r, 'failed', safe_error(err.msg()), Instance{})!
	}
}

fn perform(dir string, r Request) ! {
	project := os.dir(r.config_path)
	binding := os.read_file(os.join_path(project, '.desktop-runtime-id')) or { 'legacy' }
	if binding != r.previous_id { return error('runtime_binding_changed') }
	check(r.config_path, '')!
	if revision(r.config_path)! != r.expected_revision {
		return error('project_changed_validate_again')
	}
	old_instance := probe(r)!
	if !old_instance.ready || !old_instance.manual_restart || old_instance.boot_id != r.expected_boot || old_instance.disk_revision != r.expected_revision || old_instance.effective_revision != r.expected_revision {
		return error('instance_not_effective')
	}
	old := find_instance(r)!
	save_status(dir, r, 'stopping', '', old_instance)!
	// All validation precedes downtime. Configuration files are never rewritten.
	if revision(r.config_path)! != r.expected_revision {
		return error('project_changed_validate_again')
	}
	stop(old)!
	mut target := Identity{}
	activate(dir, r, old, mut target) or {
		rollback(dir, r, old, target, safe_error(err.msg()))!
	}
}

fn activate(dir string, r Request, old Identity, mut target Identity) ! {
	save_status(dir, r, 'starting', '', Instance{})!
	if revision(r.config_path)! != r.expected_revision {
		return error('project_changed_during_upgrade')
	}
	target = launch(binary(r.server_root, r.target_id), old)!
	instance := wait_ready(r, target, r.target_version)!
	private_write(os.join_path(os.dir(r.config_path), '.desktop-runtime-id'), r.target_id)!
	save_status(dir, r, 'completed', '', instance)!
}

fn rollback(dir string, r Request, old Identity, target Identity, failure string) ! {
	project := os.dir(r.config_path)
	save_status(dir, r, 'rolling_back', failure, Instance{}) or {}
	if target.pid > 0 && target.alive() {
		stop(target) or {
			save_status(dir, r, 'rollback_failed', 'target_process_still_alive', Instance{})!
			return
		}
	}
	mut binding_restored := true
	private_write(os.join_path(project, '.desktop-runtime-id'), r.previous_id) or { binding_restored = false }
	if (revision(r.config_path) or { '' }) != r.expected_revision {
		save_status(dir, r, 'rollback_failed', 'project_changed_during_upgrade', Instance{})!
		return
	}
	restored := launch(old.executable, old) or {
		save_status(dir, r, 'rollback_failed', 'previous_process_failed', Instance{})!
		return
	}
	if instance := wait_ready(r, restored, r.previous_version) {
		save_status(dir, r, if binding_restored { 'rolled_back' } else { 'rollback_failed' }, if binding_restored {
			failure
		} else {
			'runtime_binding_restore_failed'
		}, instance)!
	} else {
		eprintln('rollback_check_failed:' + safe_error(err.msg()))
		save_status(dir, r, 'rollback_failed', if err.msg() == 'new_process_exited' {
			'previous_process_failed'
		} else {
			'previous_version_not_effective'
		}, Instance{})!
	}
}

fn safe_error(reason string) string {
	if reason in ['whole_project_validation_failed', 'project_changed_validate_again',
		'runtime_binding_changed', 'instance_not_effective', 'process_identity_ambiguous',
		'process_identity_changed', 'old_process_still_alive', 'project_changed_during_upgrade',
		'new_process_exited', 'startup_or_effectiveness_timeout', 'admin_unavailable',
		'instance_changed', 'runtime_version_mismatch', 'process_identity_unavailable'] {
		return reason
	}
	return 'upgrade_operation_failed'
}
