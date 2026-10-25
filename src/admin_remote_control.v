module main

import config
import crypto.rand
import crypto.sha256
import json2 as json
import net
import os
import process_runtime
import sync
import time
import veb

@[heap]
struct ManualRemoteControl {
mut:
	mu                 sync.Mutex
	root               string
	boot_id            string
	effective_revision string
	manual             bool
	operation          string
	ready              bool
}

__global (
	g_manual_remote ManualRemoteControl
)

struct RemoteInstanceStatus {
	instance_id        string
	boot_id            string
	version            string
	platform           string
	config_path        string
	effective_revision string
	disk_revision      string
	ready              bool
	manual_restart     bool
	operation          RemoteRestartOperation
	error              string
}

struct RemoteRestartOperation {
	id                string
	state             string
	expected_boot     string
	expected_revision string
	pid               int
	log_path          string
	error             string
}

struct RemoteRestartRequest {
	operation_id      string
	expected_boot     string
	expected_revision string
}

struct RemoteRestartLaunch {
	operation  RemoteRestartOperation
	args       []string
	cwd        string
	executable string
	parent     int
}

fn remote_project_revision(root string) !string {
	sources := config.runtime_config_sources(root)!
	mut entries := []string{}
	for source in sources {
		entries << source.path + ':' + sha256.hexhash(os.read_file(source.path)!)
	}
	entries.sort()
	return sha256.hexhash(entries.join('\n'))
}

fn remote_control_initialize(args []string, enabled bool) ! {
	source := config.source_config_path(args)
	if source == '' { return }
	root := os.abs_path(source)
	if !os.is_file(root) { return }
	revision := remote_project_revision(root)!
	mut g := unsafe { &g_manual_remote }
	g.mu.@lock()
	defer { g.mu.unlock() }
	g.root = root
	g.boot_id = rand.bytes(16)!.hex()
	g.effective_revision = revision
	g.operation = os.getenv('VHTTPD_RESTART_OPERATION')
	$if windows {
		g.manual = false
	} $else {
		g.manual = enabled
	}
}

// If sources changed while runtime construction or warmup was in progress,
// do not claim that the initial manifest describes the loaded runtime.
fn remote_control_note_startup() {
	mut g := unsafe { &g_manual_remote }
	g.mu.@lock()
	defer { g.mu.unlock() }
	if g.root == '' { return }
	current := remote_project_revision(g.root) or { '' }
	if current != g.effective_revision {
		g.effective_revision = ''
	}
}

fn remote_control_dir(root string) !string {
	dir := os.join_path(os.dir(root), '.var', 'vhttpd', 'workbench', sha256.hexhash(root)[..16])
	// Do not publish launch arguments through a pre-existing symlink.
	mut current := os.dir(root)
	for part in ['.var', 'vhttpd', 'workbench', sha256.hexhash(root)[..16]] {
		current = os.join_path(current, part)
		if os.is_link(current) { return error('unsafe_control_directory') }
		os.mkdir_all(current)!
	}
	os.chmod(dir, 0o700)!
	return dir
}

fn remote_private_write(path string, content string) ! {
	temp := path + '.' + rand.bytes(8)!.hex()
	defer { os.rm(temp) or {} }
	// Newly generated private directory; exclusive creation also protects races.
	fd := os.open_file(temp, 'wx', 0o600)!
	mut file := fd
	defer { file.close() }
	file.write_string(content)!
	os.mv(temp, path)!
}

fn remote_id_valid(id string) bool { return id.len == 24 && id.bytes().all(it.is_hex_digit()) }

fn remote_read_operation(root string, id string) !RemoteRestartOperation {
	if !remote_id_valid(id) { return error('invalid_operation') }
	path := os.join_path(remote_control_dir(root)!, 'operation-${id}.json')
	if os.is_link(path) || os.file_size(path) > 16384 { return error('unsafe_operation') }
	return json.decode[RemoteRestartOperation](os.read_file(path)!)!
}

fn remote_write_operation(root string, operation RemoteRestartOperation) ! {
	remote_private_write(os.join_path(remote_control_dir(root)!, 'operation-${operation.id}.json'), json.encode(operation))!
}

fn remote_process_ready() bool {
	if active_runtime_is_shutting_down() { return false }
	unsafe { g_active_runtime_registry.mu.@lock() }
	apps := unsafe { g_active_runtime_registry.apps.clone() }
	configs := unsafe { g_active_runtime_registry.cfgs.clone() }
	unsafe { g_active_runtime_registry.mu.unlock() }
	if apps.len == 0 { return false }
	for app in apps {
		app.mu.@lock()
		ready := app.lifecycle.startup_ready
		app.mu.unlock()
		if !ready { return false }
	}
	for cfg in configs {
		if !cfg.serve_data_plane { continue }
		host := if cfg.host in ['', '0.0.0.0'] {
			'127.0.0.1'
		} else if cfg.host == '::' {
			'[::1]'
		} else if cfg.host.contains(':') {
			'[${cfg.host}]'
		} else {
			cfg.host
		}
		mut connection := net.dial_tcp('${host}:${cfg.port}') or { return false }
		connection.close() or {}
	}
	return true
}

fn remote_startup_failure() string {
	unsafe { g_active_runtime_registry.mu.@lock() }
	apps := unsafe { g_active_runtime_registry.apps.clone() }
	unsafe { g_active_runtime_registry.mu.unlock() }
	for app in apps {
		app.mu.@lock()
		failed := app.engines.startup_failed
		app.mu.unlock()
		if failed { return 'executor_warmup_failed' }
	}
	return ''
}

fn remote_instance_status() RemoteInstanceStatus {
	mut g := unsafe { &g_manual_remote }
	g.mu.@lock()
	root, boot, revision, manual, operation_id, cached_ready := g.root, g.boot_id, g.effective_revision, g.manual, g.operation, g.ready
	g.mu.unlock()
	if root == '' { return RemoteInstanceStatus{ error: 'instance_metadata_unavailable' } }
	disk := remote_project_revision(root) or { '' }
	startup_failure := remote_startup_failure()
	ready := (cached_ready || remote_process_ready()) && !active_runtime_is_shutting_down()
	if ready {
		g.mu.@lock()
		g.ready = true
		g.mu.unlock()
	}
	mut operation := RemoteRestartOperation{}
	if remote_id_valid(operation_id) {
		operation = remote_read_operation(root, operation_id) or { RemoteRestartOperation{} }
		if startup_failure != '' && operation.id != '' && operation.state == 'starting' {
			operation = RemoteRestartOperation{ ...operation, state: 'failed', error: startup_failure, pid: os.getpid() }
			remote_write_operation(root, operation) or {}
		}
		if ready && operation.id != '' && operation.state == 'starting' {
			operation = RemoteRestartOperation{
				...operation
				state: if operation.expected_revision == revision && disk == revision {
					'completed'
				} else {
					'config_changed'
				}
				pid:   os.getpid()
			}
			remote_write_operation(root, operation) or {}
		}
	}
	return RemoteInstanceStatus{
		instance_id:        sha256.hexhash(root)
		boot_id:            boot
		version:            vhttpd_version
		platform:           os.user_os()
		config_path:        root
		effective_revision: revision
		disk_revision:      disk
		ready:              ready
		manual_restart:     manual
		operation:          operation
		error:              if disk == '' {
			'whole_project_invalid'
		} else {
			''
		}
	}
}

@['/admin/workbench/instance'; get]
pub fn (mut app AdminApp) remote_instance_get(mut ctx Context) veb.Result {
	browser_auth_headers(mut ctx)
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(.forbidden)
		return ctx.text('Forbidden')
	}
	return ctx.json(remote_instance_status())
}

@['/admin/workbench/restart/:id'; get]
pub fn (mut app AdminApp) remote_restart_get(mut ctx Context, id string) veb.Result {
	browser_auth_headers(mut ctx)
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(.forbidden)
		return ctx.text('Forbidden')
	}
	status := remote_instance_status()
	operation := remote_read_operation(status.config_path, id) or {
		ctx.res.set_status(.not_found)
		return ctx.text('Operation not found')
	}
	return ctx.json(operation)
}

@['/admin/workbench/restart'; post]
pub fn (mut app AdminApp) remote_restart_post(mut ctx Context) veb.Result {
	browser_auth_headers(mut ctx)
	// Instance lifecycle operations are native-host only, not browser actions.
	if ctx.req.header.get(.origin) or { '' } != '' || ctx.req.header.get_custom('x-vhttpd-admin-token') or { '' } != app.admin_token || app.admin_token == '' {
		ctx.res.set_status(.forbidden)
		return ctx.text('Forbidden')
	}
	request := json.decode[RemoteRestartRequest](ctx.req.data) or {
		ctx.res.set_status(.bad_request)
		return ctx.text('Invalid restart request')
	}
	result := remote_begin_restart(request) or {
		ctx.res.set_status(.conflict)
		return ctx.json({
			'error': err.msg()
		})
	}
	ctx.res.set_status(.accepted)
	return ctx.json(result)
}

fn remote_begin_restart(request RemoteRestartRequest) !RemoteRestartOperation {
	if !remote_id_valid(request.operation_id) { return error('invalid_operation') }
	status := remote_instance_status()
	if !status.manual_restart { return error('manual_restart_not_enabled') }
	mut g := unsafe { &g_manual_remote }
	g.mu.@lock()
	defer { g.mu.unlock() }
	// Idempotent even if a previous reply was lost or the process has restarted.
	if prior := remote_read_operation(g.root, request.operation_id) {
		if prior.expected_boot != request.expected_boot || prior.expected_revision != request.expected_revision {
			return error('operation_conflict')
		}
		return prior
	}
	if g.operation != '' {
		prior := remote_read_operation(g.root, g.operation) or { RemoteRestartOperation{} }
		if prior.state in ['queued', 'starting'] { return error('restart_in_progress') }
	}
	if status.boot_id != request.expected_boot {
		return error('instance_changed')
	}
	config.load_runtime_plan_file(g.root) or { return error('whole_project_validation_failed') }
	if request.expected_revision == '' || remote_project_revision(g.root)! != request.expected_revision {
		return error('project_changed_validate_again')
	}
	dir := remote_control_dir(g.root)!
	operation := RemoteRestartOperation{ id: request.operation_id, state: 'queued', expected_boot: g.boot_id, expected_revision: request.expected_revision, log_path: os.join_path(dir, 'runtime.log') }
	launch := RemoteRestartLaunch{ operation: operation, args: os.args[1..], cwd: os.getwd(), executable: os.executable(), parent: os.getpid() }
	descriptor := os.join_path(dir, 'launch-${operation.id}.json')
	remote_private_write(descriptor, json.encode(launch))!
	remote_write_operation(g.root, operation)!
	mut helper := os.new_process(os.executable())
	helper.set_args(['--workbench-restart-helper', descriptor])
	helper.run()
	deadline := time.ticks() + 4000
	for !os.is_file(descriptor + '.armed') && time.ticks() < deadline && helper.is_alive() {
		time.sleep(15 * time.millisecond)
	}
	if !os.is_file(descriptor + '.armed') {
		helper.signal_kill()
		helper.wait()
		helper.close()
		os.rm(descriptor) or {}
		remote_write_operation(g.root, RemoteRestartOperation{ ...operation, state: 'failed', error: 'helper_not_ready' })!
		return error('restart_helper_not_ready')
	}
	helper.close()
	g.operation = operation.id
	spawn remote_release_restart(descriptor)
	return operation
}

fn remote_release_restart(descriptor string) {
	time.sleep(350 * time.millisecond)
	remote_private_write(descriptor + '.go', 'go') or { return }
	process_runtime.terminate_self()
}

fn run_manual_restart_helper(descriptor string) ! {
	if os.is_link(descriptor) || os.file_size(descriptor) > 131072 || os.stat(descriptor)!.mode & 0o077 != 0 {
		return error('unsafe_launch_descriptor')
	}
	launch := json.decode[RemoteRestartLaunch](os.read_file(descriptor)!)!
	if !remote_id_valid(launch.operation.id) || launch.parent != os.getppid() {
		return error('restart_parent_mismatch')
	}
	root := os.abs_path(config.source_config_path(launch.args))
	if descriptor != os.join_path(remote_control_dir(root)!, 'launch-${launch.operation.id}.json') {
		return error('restart_descriptor_mismatch')
	}
	defer {
		os.rm(descriptor) or {}
		os.rm(descriptor + '.armed') or {}
		os.rm(descriptor + '.go') or {}
	}
	process_runtime.detach_restart_helper(launch.operation.log_path)!
	remote_private_write(descriptor + '.armed', 'armed')!
	deadline := time.ticks() + 6000
	for !os.is_file(descriptor + '.go') && time.ticks() < deadline {
		time.sleep(20 * time.millisecond)
	}
	if !os.is_file(descriptor + '.go') {
		remote_write_operation(root, RemoteRestartOperation{ ...launch.operation, state: 'failed', error: 'restart_not_released' })!
		return
	}
	stopped := time.ticks() + 30000
	for process_runtime.pid_alive(launch.parent) && time.ticks() < stopped {
		time.sleep(50 * time.millisecond)
	}
	if process_runtime.pid_alive(launch.parent) {
		remote_write_operation(root, RemoteRestartOperation{ ...launch.operation, state: 'failed', error: 'old_process_still_alive' })!
		return
	}
	config.load_runtime_plan_file(root) or {
		remote_write_operation(root, RemoteRestartOperation{ ...launch.operation, state: 'failed', error: 'whole_project_validation_failed' })!
		return
	}
	if remote_project_revision(root)! != launch.operation.expected_revision {
		remote_write_operation(root, RemoteRestartOperation{ ...launch.operation, state: 'failed', error: 'project_changed_before_start' })!
		return
	}
	os.chdir(launch.cwd)!
	os.setenv('VHTTPD_RESTART_OPERATION', launch.operation.id, true)
	mut child := os.new_process(launch.executable)
	child.set_args(launch.args)
	child.run()
	remote_write_operation(root, RemoteRestartOperation{ ...launch.operation, state: 'starting', pid: child.pid })!
	time.sleep(1500 * time.millisecond)
	if !child.is_alive() {
		child.wait()
		remote_write_operation(root, RemoteRestartOperation{ ...launch.operation, state: 'failed', error: 'new_process_exited' })!
	}
	child.close()
}
