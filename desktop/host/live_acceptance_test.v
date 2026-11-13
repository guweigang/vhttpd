module host

import crypto.sha256
import encoding.base64
import json2 as json
import net
import net.http
import os
import time
import toml

struct LiveAcceptance {
	project            string
	profile_id         string
	config_path        string
	web_port           int
	before_boot        string
	before_revision    string
	invalid_rejected   bool
	phase              string
	disk_revision      string
	effective_revision string
	current_boot       string
	state              string
	changed_files      []string
	runtime_paths      string
	after_message      string
	before_http        int
	after_http         int
}

struct LiveSource {
	path string
}

struct LiveSourceFile {
	source LiveSource
	value  string
}

struct LiveWorkspace {
	config_path string
	files       []LiveSourceFile
}

struct LiveGraphNode {
	ref      string
	metadata map[string]string
}

struct LiveGraph {
	nodes []LiveGraphNode
}

struct LiveChange {
	path     string
	original string
	value    string
}

struct LiveBundle {
	config_path string
	files       []LiveChange
}

fn live_wait(mut manager RemoteManager) ! {
	until := time.ticks() + 30000
	for time.ticks() < until {
		manager.next_probe = 0
		manager.tick()
		if manager.snapshot.connected && !manager.snapshot.busy && manager.snapshot.instance.ready {
			return
		}
		time.sleep(100 * time.millisecond)
	}
	return error('验收项目未就绪；请在工作台查看状态。')
}

fn live_business(s &ServerSession, port int, path string) !http.Response {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	local_port := listener.addr()!.port()!
	listener.close() or {}
	binding := '127.0.0.1:${local_port}:127.0.0.1:${port}'
	mut args := s.mux_args()
	args << ['-O', 'forward', '-L', binding]
	args << s.destination_args()
	s.job.command(s.ssh_executable, args, 5000)!
	defer {
		mut cancel := s.mux_args()
		cancel << ['-O', 'cancel', '-L', binding]
		cancel << s.destination_args()
		s.job.command(s.ssh_executable, cancel, 3000) or {}
	}
	mut request := http.Request{ url: 'http://127.0.0.1:${local_port}${path}', read_timeout: 5 * time.second, max_retries: 1, disable_connection_reuse: true }
	return request.do()!
}

// Explicitly opt-in, read/write acceptance against an already authenticated SSH
// test server. Never runs in ordinary tests; no password/token is an argument.
fn test_live_remote_cross_include_acceptance() ! {
	phase := os.getenv('VHTTPD_LIVE_ACCEPTANCE_ACTION')
	if phase == '' { return }
	output := os.getenv('VHTTPD_LIVE_ACCEPTANCE_STATE')
	control := os.getenv('VHTTPD_LIVE_ACCEPTANCE_CONTROL')
	server_id := os.getenv('VHTTPD_LIVE_ACCEPTANCE_SERVER')
	servers := load_remote_servers()!
	server := servers.filter(it.id == server_id)[0]
	if !os.exists(control) || !control.ends_with('/control') || output == '' {
		return error('需要已有的 SSH 会话和验收记录目录。')
	}
	// Borrow the Desktop master. Do not call close(): it owns the control socket.
	mut session := &ServerSession{ server: server, directory: os.dir(control), state: ServerSnapshot{ connected: true, server: server, server_id: server.id, control_path: control } }
	mut report := LiveAcceptance{}
	if phase == 'prepare' {
		session.inspect()!
		println('STEP server inspection passed')
		mut profile := RemoteProfile{}
		mut port := 0
		if os.exists(output + '.baseline') {
			baseline := json.decode[LiveWorkspace](os.read_file(output + '.baseline')!)!
			profile = load_remote_profiles()!.filter(it.config_path == baseline.config_path)[0]
			root_file := baseline.files.filter(it.source.path == baseline.config_path)[0]
			port = int(toml.parse_text(root_file.value)!.value('listeners.web.port').int())
		} else {
			id := new_remote_id()!
			name := 'desktop-e2e-' + id[..8]
			port = 30000 + int(time.now().unix_milli() % 18000)
			template := project_templates()[0]
			config_text := template.config_text.replace('entry = "main.mts"', 'entry = "main.mjs"')
				.replace('runtime_profile = "node"', 'runtime_profile = "script"')
				.replace('port = ${template.web_port}', 'port = ${port}')
				.replace('port = ${template.admin_port}', 'port = ${port + 1}')
				.replace('local-development-only', new_remote_id()! + new_remote_id()!)
			engine_pos := config_text.index('[engines.app]') or { return error('template engine not found') }
			route_pos := config_text.index('[[pipelines]]') or { return error('template route not found') }
			root := 'include = ["engines.toml", "routes.toml"]\n' + config_text[..engine_pos]
			engines := config_text[engine_pos..route_pos]
			routes := config_text[route_pos..].replace('match.paths = ["*"]', 'match.paths = ["/acceptance-before"]')
			source := template.source_text.replace('"hello-vjsx"', json.encode(name))
			after_source := source.replace('Hello from vhttpd Workbench', 'Cross-include acceptance after')
			extra := 'printf %s ' + shell_quote(base64.encode_str(engines)) + ' | base64 -d > "$target/engines.toml"\n' +
				'printf %s ' + shell_quote(base64.encode_str(routes)) + ' | base64 -d > "$target/routes.toml"\n' +
				'printf %s ' + shell_quote(base64.encode_str(after_source)) + ' | base64 -d > "$target/main.after.mjs"\nchmod 600 "$target/engines.toml" "$target/routes.toml" "$target/main.after.mjs"\n'
			script := 'set -eu\numask 077\ninstance_id=' + shell_quote(id) + '\nreuse=0\nname=' + shell_quote(name) + '\nconfig=' + shell_quote(base64.encode_str(root)) + '\nsource=' + shell_quote(base64.encode_str(source)) + '\n' + $embed_file('remote_scripts/create.sh').to_string().replace('cd "$target"', extra + 'cd "$target"')
			session.shell(script, 20000)!
			session.discover_projects()!
			profile = load_remote_profiles()!.filter(it.id == id)[0]
		}
		id := profile.id
		name := profile.name
		mut manager := &RemoteManager{}
		manager.connect_with_session(profile, '', control)!
		defer { manager.disconnect() }
		live_wait(mut manager)!
		println('STEP authenticated ready')
		workspace_response := manager.request(.get, '/admin/config/workspace', '')!
		println('STEP workspace HTTP ${workspace_response.status_code}')
		workspace := json.decode[LiveWorkspace](workspace_response.body)!
		assert workspace.files.len == 3
		// Keep a private baseline so content hashes and whole-project revision can be compared later.
		if !os.exists(output + '.baseline') {
			write_project_contents(create_project_file(output + '.baseline')!, json.encode(workspace))!
		}
		assert live_business(session, port, '/acceptance-before')!.status_code == 200
		assert live_business(session, port, '/acceptance-after')!.body.contains('Hello from vhttpd Workbench')
		engine_file := workspace.files.filter(it.source.path.ends_with('/engines.toml'))[0]
		route_file := workspace.files.filter(it.source.path.ends_with('/routes.toml'))[0]
		invalid := LiveBundle{
			config_path: workspace.config_path
			files:       [
				LiveChange{ path: engine_file.source.path, original: engine_file.value, value: engine_file.value.replace('engine = "engine:app"', 'engine = "engine:missing"') },
				LiveChange{ path: route_file.source.path, original: route_file.value, value: route_file.value + '\n# invalid binding validation probe\n' },
			]
		}
		change_id := 'acceptance-invalid-' + id[..8]
		draft := manager.request(.post, '/admin/config/changesets?id=' + change_id, json.encode(invalid))!
		assert draft.status_code == 200
		validation := manager.request(.post, '/admin/config/changesets/' + change_id + '/validate', '{}')!
		println('STEP invalid-validation HTTP ${validation.status_code}')
		validation_result := json.decode[json.Any](validation.body)!.as_map()
		assert !validation_result['ok']!.bool()
		current_response := manager.request(.get, '/admin/workbench/instance', '')!
		println('STEP instance HTTP ${current_response.status_code}')
		current := json.decode[RemoteInstance](current_response.body)!
		assert current.disk_revision == manager.snapshot.instance.disk_revision
		assert current.effective_revision == manager.snapshot.instance.effective_revision
		report = LiveAcceptance{
			project:            name
			profile_id:         id
			config_path:        workspace.config_path
			web_port:           port
			before_boot:        current.boot_id
			before_revision:    current.effective_revision
			invalid_rejected:   true
			phase:              phase
			disk_revision:      current.disk_revision
			effective_revision: current.effective_revision
			current_boot:       current.boot_id
			state:              'effective'
			before_http:        200
			after_http:         200
			runtime_paths:      '/acceptance-before'
			after_message:      'Hello from vhttpd Workbench'
		}
	} else {
		report = json.decode[LiveAcceptance](os.read_file(output)!)!
		profile := load_remote_profiles()!.filter(it.id == report.profile_id)[0]
		mut manager := &RemoteManager{}
		manager.connect_with_session(profile, '', control)!
		defer { manager.disconnect() }
		live_wait(mut manager)!
		println('STEP authenticated ready')
		current := manager.snapshot.instance
		baseline := json.decode[LiveWorkspace](os.read_file(output + '.baseline')!)!
		workspace_response := manager.request(.get, '/admin/config/workspace', '')!
		println('STEP workspace HTTP ${workspace_response.status_code}')
		workspace := json.decode[LiveWorkspace](workspace_response.body)!
		mut changed := []string{}
		for file in workspace.files {
			original := baseline.files.filter(it.source.path == file.source.path)[0]
			if sha256.hexhash(file.value) != sha256.hexhash(original.value) {
				changed << os.file_name(file.source.path)
			}
		}
		changed.sort()
		assert changed == ['engines.toml', 'routes.toml']
		before_response := live_business(session, report.web_port, '/acceptance-before')!
		after_response := live_business(session, report.web_port, '/acceptance-after')!
		if phase == 'published' {
			assert current.disk_revision != current.effective_revision
			assert current.effective_revision == report.before_revision
			assert current.boot_id == report.before_boot
			assert before_response.status_code == 200 && after_response.status_code == 200
			assert after_response.body.contains('Hello from vhttpd Workbench')
		} else if phase == 'effective' {
			assert current.disk_revision == current.effective_revision && current.boot_id != report.before_boot
			assert manager.snapshot.config_status.state == .effective
			assert before_response.status_code == 200 && after_response.status_code == 200
			assert after_response.body.contains('Cross-include acceptance after')
		} else {
			return error('invalid phase')
		}
		graph := json.decode[LiveGraph](manager.request(.get, '/admin/runtime/graph', '')!.body)!
		pipeline := graph.nodes.filter(it.ref == 'pipeline:hello')[0]
		runtime_paths := pipeline.metadata['paths'] or { '' }
		assert runtime_paths == if phase == 'published' {
			'/acceptance-before'
		} else {
			'/acceptance-after'
		}
		report = LiveAcceptance{
			...report
			runtime_paths:      runtime_paths
			after_message:      if phase == 'effective' {
				'Cross-include acceptance after'
			} else {
				'Hello from vhttpd Workbench'
			}
			phase:              phase
			disk_revision:      current.disk_revision
			effective_revision: current.effective_revision
			current_boot:       current.boot_id
			state:              manager.snapshot.config_status.state.str()
			changed_files:      changed
			before_http:        before_response.status_code
			after_http:         after_response.status_code
		}
	}
	os.write_file(output, json.encode(report))!
	os.chmod(output, 0o600)!
	os.write_file(output + '.' + phase, json.encode(report))!
	os.chmod(output + '.' + phase, 0o600)!
	println('PASS live remote acceptance: ' + phase + ' project=' + report.project + ' state=' + report.state)
}

struct LiveFailureAcceptance {
	project                  string
	profile_id               string
	config_path              string
	web_port                 int
	healthy_boot             string
	healthy_revision         string
	healthy_paths            string
	failure_boot             string
	failure_revision         string
	recovery_revision        string
	phase                    string
	ready                    bool
	current_boot             string
	disk_revision            string
	loaded_revision          string
	operation_state          string
	operation_error          string
	config_status            string
	engine_entry             string
	route_paths              string
	business_status          int
	coherent_include_version bool
}

fn live_failure_wait(mut manager RemoteManager, failed bool) ! {
	until := time.ticks() + 45000
	for time.ticks() < until {
		manager.next_probe = 0
		manager.tick()
		if manager.snapshot.connected && !manager.snapshot.busy {
			if failed && manager.snapshot.instance.operation.state == 'failed' && !manager.snapshot.instance.ready {
				return
			}
			if !failed && manager.snapshot.instance.ready { return }
		}
		time.sleep(150 * time.millisecond)
	}
	return error('未达到预期的验收状态；未自动重复重启。')
}

fn test_live_remote_failure_and_retry_acceptance() ! {
	phase := os.getenv('VHTTPD_LIVE_FAILURE_ACTION')
	if phase == '' { return }
	state_path := os.getenv('VHTTPD_LIVE_ACCEPTANCE_STATE')
	control := os.getenv('VHTTPD_LIVE_ACCEPTANCE_CONTROL')
	base := json.decode[LiveAcceptance](os.read_file(state_path)!)!
	profile := load_remote_profiles()!.filter(it.id == base.profile_id)[0]
	server := load_remote_servers()!.filter(it.id == profile.server_id)[0]
	if !os.exists(control) || !os.file_name(os.dir(profile.config_path)).starts_with('desktop-e2e-') {
		return error('仅允许已登记的独立验收项目。')
	}
	mut session := &ServerSession{ server: server, directory: os.dir(control), state: ServerSnapshot{ connected: true, server: server, server_id: server.id, control_path: control } }
	mut manager := &RemoteManager{}
	manager.connect_with_session(profile, '', control)!
	defer { manager.disconnect() }
	live_failure_wait(mut manager, phase in ['failed', 'repaired-published'])!
	output := state_path + '.failure'
	mut report := LiveFailureAcceptance{}
	if phase == 'prepare' {
		current := manager.snapshot.instance
		assert manager.snapshot.config_status.state == .effective
		workspace := json.decode[LiveWorkspace](manager.request(.get, '/admin/config/workspace', '')!.body)!
		assert workspace.files.len == 3
		os.write_file(output + '.baseline', json.encode(workspace))!
		os.chmod(output + '.baseline', 0o600)!
		// Valid module syntax and an existing file: only executor initialization fails.
		failure_source := "throw new Error('acceptance-only startup failure');\nexport default function handle(ctx) { return ctx.json({ok:false}, 500); }\n"
		script := 'set -eu\numask 077\np=' + shell_quote(os.join_path(os.dir(profile.config_path), 'main.fail.mjs')) + '\nprintf %s ' + shell_quote(base64.encode_str(failure_source)) + ' | base64 -d > "$p"\nchmod 600 "$p"\n'
		session.shell(script, 6000)!
		response := live_business(session, base.web_port, '/acceptance-after')!
		assert response.status_code == 200 && response.body.contains('Cross-include acceptance after')
		healthy_graph := json.decode[LiveGraph](manager.request(.get, '/admin/runtime/graph', '')!.body)!
		healthy_paths := healthy_graph.nodes.filter(it.ref == 'pipeline:hello')[0].metadata['paths'] or { '' }
		report = LiveFailureAcceptance{
			healthy_paths:            healthy_paths
			project:                  base.project
			profile_id:               profile.id
			config_path:              profile.config_path
			web_port:                 base.web_port
			healthy_boot:             current.boot_id
			healthy_revision:         current.effective_revision
			phase:                    phase
			ready:                    true
			current_boot:             current.boot_id
			disk_revision:            current.disk_revision
			loaded_revision:          current.effective_revision
			operation_state:          current.operation.state
			config_status:            manager.snapshot.config_status.state.str()
			engine_entry:             'main.after.mjs'
			route_paths:              healthy_paths
			business_status:          200
			coherent_include_version: true
		}
	} else {
		report = json.decode[LiveFailureAcceptance](os.read_file(output)!)!
		current := manager.snapshot.instance
		workspace := json.decode[LiveWorkspace](manager.request(.get, '/admin/config/workspace', '')!.body)!
		baseline := json.decode[LiveWorkspace](os.read_file(output + '.baseline')!)!
		mut changed := []string{}
		for file in workspace.files {
			original := baseline.files.filter(it.source.path == file.source.path)[0]
			if file.value != original.value { changed << os.file_name(file.source.path) }
		}
		changed.sort()
		expected_changed := if phase in ['repaired-published', 'effective'] {
			if report.healthy_paths == '/failure-recovered' { []string{} } else { ['routes.toml'] }
		} else {
			['engines.toml', 'routes.toml']
		}
		assert changed == expected_changed
		graph := json.decode[LiveGraph](manager.request(.get, '/admin/runtime/graph', '')!.body)!
		route_paths := graph.nodes.filter(it.ref == 'pipeline:hello')[0].metadata['paths'] or { '' }
		plan := json.decode[json.Any](manager.request(.get, '/admin/runtime/plan', '')!.body)!.as_map()
		entry := plan['engines']!.as_map()['app']!.as_map()['options']!.as_map()['strings']!.as_map()['entry']!.str()
		response := live_business(session, base.web_port, '/failure-recovered') or { http.Response{} }
		if phase == 'published' {
			assert current.ready && current.boot_id == report.healthy_boot
			assert current.effective_revision == report.healthy_revision && current.disk_revision != current.effective_revision
			assert entry.ends_with('main.after.mjs') && route_paths == report.healthy_paths
			assert response.status_code == 200 && response.body.contains('Cross-include acceptance after')
			report = LiveFailureAcceptance{ ...report, failure_revision: current.disk_revision }
		} else if phase == 'failed' {
			assert !current.ready && current.boot_id != report.healthy_boot
			assert current.operation.state == 'failed' && current.operation.error == 'executor_warmup_failed'
			assert manager.snapshot.config_status.state == .pending && manager.snapshot.config_status.pending
			assert current.disk_revision == report.failure_revision && current.effective_revision == report.failure_revision
			assert entry.ends_with('main.fail.mjs') && route_paths == '/failure-attempt'
			assert response.status_code != 200
			report = LiveFailureAcceptance{ ...report, failure_boot: current.boot_id }
		} else if phase == 'repaired-published' {
			assert !current.ready && current.boot_id == report.failure_boot && current.operation.state == 'failed'
			assert current.disk_revision != current.effective_revision && current.effective_revision == report.failure_revision
			assert entry.ends_with('main.fail.mjs') && route_paths == '/failure-attempt'
			assert response.status_code != 200
			report = LiveFailureAcceptance{ ...report, recovery_revision: current.disk_revision }
		} else if phase == 'effective' {
			assert current.ready && current.boot_id != report.failure_boot
			assert current.disk_revision == current.effective_revision && current.effective_revision == report.recovery_revision
			assert current.operation.state == 'completed' && manager.snapshot.config_status.state == .effective
			assert entry.ends_with('main.after.mjs') && route_paths == '/failure-recovered'
			assert response.status_code == 200 && response.body.contains('Cross-include acceptance after')
		} else {
			return error('invalid acceptance phase')
		}
		report = LiveFailureAcceptance{
			...report
			phase:                    phase
			ready:                    current.ready
			current_boot:             current.boot_id
			disk_revision:            current.disk_revision
			loaded_revision:          current.effective_revision
			operation_state:          current.operation.state
			operation_error:          current.operation.error
			config_status:            manager.snapshot.config_status.state.str()
			engine_entry:             os.file_name(entry)
			route_paths:              route_paths
			business_status:          response.status_code
			coherent_include_version: true
		}
	}
	os.write_file(output, json.encode(report))!
	os.chmod(output, 0o600)!
	os.write_file(output + '.' + phase, json.encode(report))!
	os.chmod(output + '.' + phase, 0o600)!
	println('PASS live restart failure/retry: ' + phase + ' ready=' + report.ready.str() + ' operation=' + report.operation_state + ' config=' + report.config_status)
}

// Opt-in live recovery checks borrow the Desktop session without owning its lifetime.
fn test_live_remote_session_recovery_acceptance() ! {
	phase := os.getenv('VHTTPD_LIVE_RECOVERY_ACTION')
	if phase == '' { return }
	assert phase in ['pending', 'restored']
	state_path := os.getenv('VHTTPD_LIVE_ACCEPTANCE_STATE')
	control := os.getenv('VHTTPD_LIVE_ACCEPTANCE_CONTROL')
	baseline := json.decode[LiveFailureAcceptance](os.read_file(state_path + '.failure.effective')!)!
	profiles := load_remote_profiles()!
	matches := profiles.filter(it.config_path == baseline.config_path)
	assert matches.len == 1
	profile := matches[0]
	server := load_remote_servers()!.filter(it.id == profile.server_id)[0]
	if !os.exists(control) || !os.file_name(os.dir(profile.config_path)).starts_with('desktop-e2e-') {
		return error('仅允许已登记的独立验收项目。')
	}
	mut session := &ServerSession{ server: server, directory: os.dir(control), state: ServerSnapshot{ connected: true, server: server, server_id: server.id, control_path: control } }
	mut manager := &RemoteManager{}
	manager.connect_with_session(profile, '', control)!
	defer { manager.disconnect() }
	live_failure_wait(mut manager, false)!
	current := manager.snapshot.instance
	assert current.boot_id == baseline.current_boot && current.effective_revision == baseline.loaded_revision
	assert current.operation.state == 'completed'
	graph := json.decode[LiveGraph](manager.request(.get, '/admin/runtime/graph', '')!.body)!
	paths := graph.nodes.filter(it.ref == 'pipeline:hello')[0].metadata['paths'] or { '' }
	assert paths == baseline.route_paths
	workspace := json.decode[LiveWorkspace](manager.request(.get, '/admin/config/workspace', '')!.body)!
	assert workspace.files.len == 3
	if phase == 'pending' {
		assert manager.snapshot.config_status.state == .pending && manager.snapshot.config_status.pending
		assert current.disk_revision != current.effective_revision
		assert workspace.files.any(os.file_name(it.source.path) == 'routes.toml' && it.value.contains('/reconnect-acceptance'))
		assert workspace.files.any(os.file_name(it.source.path) == 'engines.toml' && it.value.contains('./main.after.mjs'))
	} else {
		assert manager.snapshot.config_status.state == .effective && !manager.snapshot.config_status.pending
		assert current.disk_revision == current.effective_revision
	}
	response := live_business(session, baseline.web_port, baseline.route_paths)!
	assert response.status_code == 200 && response.body.contains('Cross-include acceptance after')
	report := LiveFailureAcceptance{ ...baseline, profile_id: profile.id, phase: phase, current_boot: current.boot_id, disk_revision: current.disk_revision, loaded_revision: current.effective_revision, config_status: manager.snapshot.config_status.state.str(), business_status: response.status_code }
	output := state_path + '.recovery.' + phase
	os.write_file(output, json.encode(report))!
	os.chmod(output, 0o600)!
	println('PASS live session recovery: ' + phase + ' unchanged boot, HTTP 200, whole-project status=' + report.config_status)
}
