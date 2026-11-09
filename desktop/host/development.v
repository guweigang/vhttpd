module host

import config
import app_bundle
import crypto.sha256
import json2 as json
import net
import net.http
import os
import sync
import time

@[heap]
pub struct DevelopmentAccess {
mut:
	source_root   string
	source_inode  u64
	source_dev    u64
	revoked       bool
	expires_at    i64
	runtime_paths []string
	selection     DevelopmentSelection
	mu            &sync.Mutex = sync.new_mutex()
}

pub fn (a &DevelopmentAccess) is_revoked() bool {
	a.mu.@lock()
	defer { a.mu.unlock() }
	return a.revoked || (a.expires_at > 0 && time.now().unix() >= a.expires_at)
}

pub fn (mut a DevelopmentAccess) revoke() {
	a.mu.@lock()
	defer { a.mu.unlock() }
	a.revoked = true
}

pub fn new_development_grant(expires_at i64) &DevelopmentAccess {
	return &DevelopmentAccess{ expires_at: expires_at }
}

// Calls have their own reply channel: MCP never consumes the GUI snapshot stream.
pub struct DevelopmentCall {
pub:
	tool            string
	project         Project
	application     string
	directory       string
	generation      u64
	arguments       string
	root            string
	binary          string
	desktop_version string
	grant           &DevelopmentAccess    = unsafe { nil }
	access          &DevelopmentAccess    = &DevelopmentAccess{}
	reply           chan DevelopmentReply = chan DevelopmentReply{cap: 1}
}

pub struct DevelopmentReply {
pub:
	value string
	error bool
}

struct DevelopmentArgs {
	name             string
	directory        string
	entry            string
	topic            string
	protocol         string
	message          string
	timeout_ms       int = 3000
	auth_ref string
	tls_trust string = 'system'
	tls_server_name string
	max_items        int = 4
	binding_revision u64
	template         string
	component_port   int
	path             string
	id               string
	domain           string
	kind             string
	listener         string
	method           string
	body             string
	search           string
	limit            int = 100
	files            []DevelopmentEdit
	platform         string
	channel          string = 'all'
	tag              string
	package_id       string
}

struct DevelopmentEdit {
	path    string
	content string
	// Empty revision means a new file, never an unconditional overwrite.
	revision string
}

struct DevelopmentFile {
	path     string
	revision string
	size     int
}

struct DevelopmentChange {
	path    string
	before  string
	after   string
	existed bool
	mode    int
}

struct DevelopmentPreview {
	source_workspace bool
	id               string
	application_id   string
	source_root      string
	project          Project
	files            []DevelopmentChange
	baseline         []DevelopmentFile
}

struct DevelopmentState {
mut:
	source_workspace  bool
	source_plans      map[string]SourceWorkspacePlan
	application       DevelopmentApplication
	previews          map[string]DevelopmentPreview
	applied           map[string]DevelopmentPreview
	secrets           map[string]string
	component_plan_id string
	component_access  &DevelopmentAccess = unsafe { nil }
}

fn (mut d DevelopmentState) mask(text string) string {
	mut safe := text
	mut secrets := d.secrets.values()
	secrets.sort(a.len > b.len)
	for secret in secrets {
		if secret == '' { continue }
		encoded := json.encode(secret)
		if encoded.len > 2 {
			safe = safe.replace(encoded[1..encoded.len - 1], '<vhttpd-secret-' + sha256.hexhash(secret)[..16] + '>')
		}
		safe = safe.replace(secret, '<vhttpd-secret-' + sha256.hexhash(secret)[..16] + '>')
	}
	return safe
}

fn (d &DevelopmentState) reveal(text string) !string {
	mut value := text
	for marker, secret in d.secrets { value = value.replace(marker, secret) }
	if value.contains('<vhttpd-secret-') {
		return error('unknown_secret_placeholder: read the file again')
	}
	return value
}

fn development_collect_secrets(value json.Any, protected bool, mut secrets []string) {
	match value {
		map[string]json.Any {
			for key, child in value {
				development_collect_secrets(child, protected || app_bundle.sensitive(key), mut secrets)
			}
		}
		[]json.Any {
			for child in value { development_collect_secrets(child, protected, mut secrets) }
		}
		string {
			if value != '' && (protected || (value.contains('://') && (value.contains('@') || value.contains('?')))) {
				secrets << value
			}
		}
		else {}
	}
}

fn (mut d DevelopmentState) safe_json(value json.Any) json.Any {
	match value {
		map[string]json.Any {
			mut result := map[string]json.Any{}
			for key, child in value { result[key] = d.safe_json(child) }
			return result
		}
		[]json.Any { return value.map(d.safe_json(it)) }
		string { return d.mask(value) }
		else { return value }
	}
}

fn (mut d DevelopmentState) remember_secrets(m &Manager) {
	mut secrets := []string{}
	if m.token != '' { secrets << m.token }
	if m.info.config_token != '' { secrets << m.info.config_token }
	if plan := config.load_runtime_plan_file(m.project.config_path) {
		if value := json.decode[json.Any](json.encode(plan)) {
			development_collect_secrets(value, false, mut secrets)
		}
	}
	for secret in secrets {
		if secret != '' {
			d.secrets['<vhttpd-secret-' + sha256.hexhash(secret)[..16] + '>'] = secret
		}
	}
}

// The dedicated channel is consumed by the same owner as GUI commands.
fn (mut d DevelopmentState) execute(mut m Manager, call DevelopmentCall) DevelopmentReply {
	if call.access.is_revoked() || (!isnil(call.grant) && call.grant.is_revoked()) {
		return DevelopmentReply{ error: true, value: 'MCP service disabled' }
	}
	if call.tool == '_runtime_package_select' {
		value := d.select_runtime_package(mut m, call) or { return DevelopmentReply{ error: true, value: err.msg() } }
		return DevelopmentReply{ value: value }
	}
	if call.tool == '_open_source_workspace' {
		value := d.open_source_workspace(mut m, call) or { return DevelopmentReply{ error: true, value: err.msg() } }
		return DevelopmentReply{ value: value }
	}
	if call.tool == '_select_application' {
		result := d.select_application(mut m, call) or { return DevelopmentReply{ error: true, value: err.msg() } }
		return DevelopmentReply{ value: result }
	}
	selection := call.access.selection()
	d.application = DevelopmentApplication{}
	d.source_workspace = selection.source_workspace
	if selection.source_workspace {
		value := d.execute_source_workspace(mut m, call) or { return DevelopmentReply{ error: true, value: d.mask(err.msg()).replace(call.access.source_root, '<source-workspace>').replace(workbench_data_dir(), '<desktop-private>') } }
		parsed := json.decode[json.Any](value) or { return DevelopmentReply{ value: d.mask(value) } }
		return DevelopmentReply{ value: json.encode(d.safe_json(parsed)) }
	}
	if selection.application.id != '' {
		if (call.generation != selection.generation && !(call.tool == 'context_get' && isnil(call.grant))) || m.project != selection.project {
			return DevelopmentReply{ error: true, value: 'application_selection_changed: call context_get again' }
		}
		args := json.decode[DevelopmentArgs](call.arguments) or {
			return DevelopmentReply{ error: true, value: 'invalid_arguments' }
		}
		if (args.binding_revision != 0 || (!isnil(call.grant) && call.tool != 'context_get'))
			&& args.binding_revision != selection.generation {
			return DevelopmentReply{ error: true, value: 'binding_changed: call context_get again' }
		}
		if call.tool in ['project_create', 'project_select'] {
			return DevelopmentReply{ error: true, value: 'select_application_in_desktop' }
		}
		apps := development_applications(m.project) or { return DevelopmentReply{ error: true, value: err.msg() } }
		current := apps.filter(it.id == selection.application.id && it.root == selection.application.root)
		if current.len != 1 {
			return DevelopmentReply{ error: true, value: 'application_source_changed' }
		}
		d.application = current[0]
	}
	d.remember_secrets(m)
	value := d.dispatch(mut m, call) or {
		return DevelopmentReply{ error: true, value: d.mask(err.msg()) }
	}
	d.remember_secrets(m)
	parsed := json.decode[json.Any](value) or { return DevelopmentReply{ value: d.mask(value) } }
	return DevelopmentReply{ value: json.encode(d.safe_json(parsed)) }
}

fn development_project(root string, path string) !Project {
	file := development_target(root, path)!
	project := project_from_file(file, os.dir(file))!
	mut seen := map[string]bool{}
	development_config_boundary(project.workdir, project.config_path, map[string]string{}, mut seen)!
	return project
}

fn development_selected(root string, m &Manager) ! {
	if m.project.config_path == '' { return error('select_project_first') }
	rel := os.path_rel(root, m.project.config_path)!
	if development_target(root, rel)! != m.project.config_path {
		return error('project_outside_workspace')
	}
}

fn (mut d DevelopmentState) dispatch(mut m Manager, call DevelopmentCall) !string {
	a := json.decode[DevelopmentArgs](call.arguments)!
	if call.tool == 'templates_list' { return json.encode(project_templates()) }
	if call.tool == 'application_templates_list' { return json.encode(application_templates()) }
	if call.tool == 'guidance_get' && a.topic in ['workflow', 'pipeline', 'wechat-cloud-functions',
		'codexbot', 'deploy', 'debug'] {
		return desktop_development_guidance(call.access.selection(), a.topic, call.desktop_version)!
	}
	if call.tool.starts_with('source_workspace_') {
		return d.source_workspace_request(mut m, call, a)!
	}
	if d.source_workspace && call.tool == 'context_get' {
		return source_workspace_context(m, call.access)!
	}
	if call.tool == 'project_create' {
		if !isnil(m.process) { return error('stop_current_runtime_first') }
		if os.is_link(call.root) || !os.is_dir(call.root) || os.real_path(call.root) != os.norm_path(call.root) {
			return error('workspace_unavailable')
		}
		project := create_project(CreateProjectOptions{ name: a.name, parent_dir: call.root, template: a.template })!
		m.select_project(project)!
		return json.encode(project)
	}
	if call.tool == 'project_select' {
		project := development_project(call.root, a.path)!
		m.select_project(project)!
		return json.encode(project)
	}
	development_selected(call.root, m)!
	match call.tool {
		'application_install_prepare', 'application_install_apply' {
			return d.install_application(mut m, call, a)!
		}
		'context_get' {
			if d.application.id != '' {
				return development_bound_context(m, call.access.selection())
			}
			return json.encode({
				'project':     json.encode(m.project)
				'application': json.encode(d.application)
				'runtime':     call.binary
				'workflow':    'Read files and revisions; prepare changes; validate; stop runtime; apply; start; request; inspect logs. All applications share one process. Changes are recoverable for this Desktop session.'
				'vjsx':        'Use the vjsx-http/vjsx-api templates with script profile. export default function handle(ctx) { return ctx.json({ok:true},200); }. Request: ctx.method, ctx.path, ctx.queryParam(name,default). Node/npm APIs are unavailable in script profile.'
				'schema':      'Use schema_get to discover configuration domains, kinds, fields and defaults for the selected runtime.'
			})
		}
		'guidance_get' {
			return d.guidance(m, call.access.selection(), a.topic, call.desktop_version)!
		}
		'runtime_package_get' {
			info := inspect_runtime(call.binary, os.executable(), RuntimeJob{})
			return json.encode({
				'version':   json.Any(info.version)
				'source':    json.Any(info.source)
				'available': json.Any(info.ready)
				'message':   json.Any(info.message)
			})
		}
		'runtime_releases_list', 'runtime_packages_list', 'runtime_package_probe' {
			return development_packages(m, call, a)!
		}
		'runtime_diagnostics_get' {
			if !isnil(call.grant) { return error('local_session_required') }
			return development_diagnostics(m, a.topic)!
		}
		'schema_get' { return development_schema(m, call.binary, a.domain, a.kind)! }
		'files_list' { return json.encode(d.application_files(m)!) }
		'files_read' {
			path := d.file_target(m, a.path)!
			value := development_read(path)!
			return json.encode({
				'path':     a.path
				'revision': sha256.hexhash(value)
				'content':  value
			})
		}
		'changes_prepare' { return d.prepare(m, a.files)! }
		'changes_validate' {
			preview := d.previews[a.id] or { return error('unknown_changeset') }
			if preview.application_id != d.application.id {
				return error('application_selection_changed')
			}
			development_validate(m, preview)!
			return '{"valid":true,"source_validation":"runtime startup required"}'
		}
		'changes_apply' {
			preview := d.previews[a.id] or { return error('unknown_changeset') }
			if preview.application_id != d.application.id {
				return error('application_selection_changed')
			}
			development_apply(mut m, preview)!
			d.applied[a.id] = preview
			d.previews.delete(a.id)
			return json.encode({
				'applied': a.id
				'runtime': 'stopped; start and verify business response'
			})
		}
		'changes_restore' {
			preview := d.applied[a.id] or { return error('unknown_applied_changeset') }
			if preview.application_id != d.application.id {
				return error('application_selection_changed')
			}
			development_restore(mut m, preview)!
			d.applied.delete(a.id)
			return '{"restored":true,"runtime":"stopped"}'
		}
		'changes_discard' {
			d.previews.delete(a.id)
			d.applied.delete(a.id)
			return '{"discarded":true,"files_unchanged":true}'
		}
		'runtime_status' {
			mut status := {
				'phase':        m.phase.str()
				'project':      m.project.name
				'pid':          m.snapshot().pid.str()
				'message':      m.message
				'app_url':      m.info.app_url
				'config_state': m.snapshot().config_status.state.str()
				'affects':      'all_applications_in_environment'
			}
			if !isnil(call.grant) {
				ready := m.installation_ready_now()!
				status['readiness'] = if ready { 'ready' } else { 'pending' }
			}
			return json.encode(status)
		}
		'runtime_start', 'runtime_restart' {
			if d.source_workspace && !os.is_file(m.project.config_path) {
				return error('source_configuration_missing: create and validate the configured TOML entry')
			}
			if call.tool == 'runtime_restart' { m.installation_stop()! }
			m.start(m.project, call.binary)!
			// The public request has a shorter deadline than runtime warmup.
			// Keep the process owned by the worker and let its normal tick
			// advance readiness after this Relay request has returned.
			if !isnil(call.grant) {
				return '{"accepted":true,"phase":"starting","next":"runtime_status"}'
			}
			m.installation_ready()!
			return '{"ready":true}'
		}
		'runtime_stop' {
			m.installation_stop()!
			return '{"stopped":true}'
		}
		'logs_query' {
			if d.application.id != '' && !d.source_workspace && m.phase == .running {
				logs := m.workspace.application_logs[d.application.id] or { return error('application_logs_not_ready') }
				return json.encode(logs)
			}
			limit := if a.limit < 1 {
				1
			} else if a.limit > 200 {
				200
			} else {
				a.limit
			}
			lines := m.snapshot().logs.split_into_lines().filter(a.search == '' || it.contains(a.search))
			return json.encode(lines[if lines.len > limit { lines.len - limit } else { 0 }..])
		}
		'application_probe_options_get' {
			return protocol_probe_options(config.load_runtime_plan_file(m.project.config_path)!, d.application.listeners)
		}
		'application_protocol_probe' {
			if d.application.id != '' && a.listener !in d.application.listeners {
				return error('listener_belongs_to_another_application')
			}
			value := local_protocol_probe(m, ProtocolProbeArgs{ protocol: a.protocol, listener: a.listener, path: a.path, message: a.message, timeout_ms: a.timeout_ms, max_items: a.max_items, auth_ref: a.auth_ref, tls_trust: a.tls_trust, tls_server_name: a.tls_server_name })!
			if call.access.is_revoked() || (!isnil(call.grant) && call.grant.is_revoked()) || call.access.selection().generation != call.generation {
				return error('protocol_probe_binding_changed')
			}
			return value
		}
		'application_request' {
			if d.application.id != '' && a.listener !in d.application.listeners {
				return error('listener_belongs_to_another_application')
			}
			return development_request(m, a)!
		}
		else { return error('unknown_development_tool') }
	}
}

fn development_request(m &Manager, a DevelopmentArgs) !string {
	if m.phase != .running { return error('runtime_not_running') }
	if !a.path.starts_with('/') || a.path.starts_with('//') || a.path.contains('://') || a.path.bytes().any(it < 32) {
		return error('invalid_request_path')
	}
	if a.body.len > 65536 { return error('request_too_large') }
	method := if a.method == '' { 'GET' } else { a.method.to_upper() }
	if method !in ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'] {
		return error('invalid_method')
	}
	plan := config.load_runtime_plan_file(m.project.config_path)!
	listener := plan.listeners[a.listener] or { return error('choose_business_listener_from_config') }
	if control := plan.control.listener {
		if control.id == a.listener { return error('admin_requests_forbidden') }
	}
	if listener.protocol != 'http' || listener.tls.enabled || listener.port < 1 {
		return error('local_http_listener_required')
	}
	if listener.host !in ['127.0.0.1', 'localhost', '0.0.0.0', '::', '::1', ''] {
		return error('local_listener_required')
	}
	request_host := if listener.host in ['::', '::1'] { '[::1]' } else { '127.0.0.1' }
	mut request := http.Request{ url: 'http://${request_host}:${listener.port}${a.path}', method: http.method_from_str(method), data: a.body, allow_redirect: false, read_timeout: 5 * time.second, write_timeout: 5 * time.second, max_retries: 1, disable_connection_reuse: true }
	request.add_header(.content_type, 'application/json')
	response := request.do()!
	if response.body.len > 1024 * 1024 { return error('response_too_large') }
	return json.encode({
		'status': response.status_code.str()
		'body':   response.body
	})
}

// Holding a socket also rejects an externally started runtime while editing offline.
fn development_guard(m &Manager) !&net.TcpListener {
	if !isnil(m.process) || m.phase in [.starting, .stopping] {
		return error('stop_runtime_before_editing: affects all applications')
	}
	info := inspect_project(m.project) or { m.info }
	if info.admin_port < 1 { return error('admin_endpoint_unknown') }
	return net.listen_tcp(.ip, '${url_host(info.admin_host)}:${info.admin_port}') or { return error('runtime_admin_port_in_use') }
}

fn development_schema(m &Manager, binary string, domain string, kind string) !string {
	if kind != '' && domain == '' { return error('schema_domain_required') }
	mut path := '/admin/schema'
	for part in [domain, kind] {
		if part == '' { continue }
		if !part.bytes().all(it.is_alnum() || it in [u8(`-`), `_`]) {
			return error('invalid_schema_name')
		}
		path += '/' + part
	}
	if m.phase == .running {
		body := workspace_get(m.info.admin_url.all_before('/admin/ui/'), m.token, path)!
		mut schema := json.decode[map[string]json.Any](body)!
		schema['source'] = json.Any('live_admin')
		return json.encode(schema)
	}
	if !os.is_executable(binary) {
		return error('runtime_schema_unavailable: select a runtime package')
	}
	body := (RuntimeJob{}).command(binary, ['--schema'], 5000) or {
		return error('runtime_schema_unavailable: this package could not provide offline schema')
	}
	result := json.decode[map[string]json.Any](body) or {
		return error('runtime_schema_unavailable: invalid runtime package response')
	}
	source := result['source'] or { return error('runtime_schema_unavailable: missing source') }
	version := result['runtime_version'] or { return error('runtime_schema_unavailable: missing runtime version') }
	payload := result['schema'] or { return error('runtime_schema_unavailable: missing schema') }
	if source.str() != 'runtime_package' || version.str() == '' || payload.as_map().len == 0 {
		return error('runtime_schema_unavailable: invalid runtime package response')
	}
	mut schema := payload.as_map().clone()
	if domain != '' {
		schema = development_schema_item(schema['domains'] or { json.Any('') }, domain, 'schema_domain_not_found')!
	}
	if kind != '' {
		schema = development_schema_item(schema['kinds'] or { json.Any('') }, kind, 'schema_kind_not_found')!
	}
	schema['source'] = source
	schema['runtime_version'] = version
	return json.encode(schema)
}

fn development_schema_item(items json.Any, id string, missing string) !map[string]json.Any {
	for value in items.as_array() {
		item := value.as_map()
		name := item['id'] or { continue }
		if name.str() == id { return item.clone() }
	}
	return error(missing)
}
