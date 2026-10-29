module host

import config
import json2 as json
import crypto.sha256
import encoding.base64
import os
import toml

struct RemoteProjectCandidate {
	path   string
	marker string
	token  string
	port   int
	runtime_id string
	runtime_path string
}

fn remote_absolute_path(cwd string, path string) !string {
	if path == '' || path.contains('\n') || path.contains('\r') || path.contains('\x00') {
		return error('invalid remote path')
	}
	resolved := config.resolve_config_path(cwd, path)
	if !resolved.starts_with('/') { return error('invalid remote path') }
	return resolved
}

fn running_project_candidate(cwd string, command string) !RemoteProjectCandidate {
	args := command.split('\x00')
	if args.any(it in ['--workbench-restart-helper', '--workbench-upgrade-helper', '--workbench-upgrade-check','--workbench-deploy-helper','--workbench-deploy-prepare','--workbench-deploy-version']) { return error('management_helper_process') }
	mut path := ''
	mut token := ''
	mut port := 0
	for i := 1; i < args.len; i++ {
		match args[i] {
			'--config' {
				if i + 1 < args.len {
					i++
					path = args[i]
				}
			}
			'--admin-token' {
				if i + 1 < args.len {
					i++
					token = args[i]
				}
			}
			'--admin-port' {
				if i + 1 < args.len {
					i++
					port = args[i].int()
				}
			}
			else {
				if args[i].starts_with('--config=') {
					path = args[i].all_after('--config=')
				} else if args[i].ends_with('.toml') && !args[i].starts_with('-') && path == '' {
					path = args[i]
				}
			}
		}
	}
	if path == '' { path = 'vhttpd.toml' }
	return RemoteProjectCandidate{ path: remote_absolute_path(cwd, path)!, token: token, port: port }
}

// Read includes through SSH, never by falling back to paths on this computer.
fn (mut s ServerSession) read_project_sources(path string, mut sources map[string]string, mut visiting map[string]bool) ! {
	if visiting[path] { return error('include cycle') }
	if path in sources { return }
	if sources.len >= 32 { return error('too many includes') }
	visiting[path] = true
	script := 'set -eu\np=' + shell_quote(path) + '\n[ -f "$p" ] && [ -r "$p" ] || exit 1\n[ "$(wc -c < "$p")" -le 65536 ] || exit 1\nbase64 < "$p"\n'
	encoded := s.shell_limited(script, 8000, 100000)!
	text := base64.decode_str(encoded.replace('\n', '').replace('\r', ''))
	doc := toml.parse_text(text)!
	sources[path] = text
	includes := doc.value('include')
	if includes is []toml.Any {
		for value in includes {
			child := remote_absolute_path(os.dir(path), value.string())!
			s.read_project_sources(child, mut sources, mut visiting)!
		}
	}
	visiting.delete(path)
}

fn discovered_profile(server RemoteServer, candidate RemoteProjectCandidate, sources map[string]string) !RemoteProfile {
	root := sources[candidate.path] or { return error('missing root') }
	doc := toml.parse_text(root)!
	mut token := ''
	mut port := 0
	mut host_name := ''
	// Environment-based credentials cannot be resolved against the Mac's env.
	for _, text in sources {
		source := toml.parse_text(text)!
		if source.value('control.token').string().contains('$') || source.value('admin.token').string().contains('$') {
			return error('environment credential requires explicit import')
		}
	}
	if doc.value('version').int() == 2 {
		plan := config.load_runtime_plan_with_overrides(candidate.path, sources)!
		ref := plan.control.listener or { return error('missing control listener') }
		listener := plan.listeners[ref.id] or { return error('missing control listener') }
		if listener.protocol != 'http' || listener.tls.enabled {
			return error('unsupported admin transport')
		}
		token = plan.control.token
		port = listener.port
		host_name = listener.host
	} else {
		token = doc.value('admin.token').string()
		port = doc.value('admin.port').int()
		host_name = doc.value('admin.host').string()
	}
	if candidate.token != '' { token = candidate.token }
	if candidate.port > 0 { port = candidate.port }
	if host_name !in ['127.0.0.1', 'localhost', '0.0.0.0', ''] {
		return error('admin must be reachable on remote IPv4 loopback')
	}
	marker := candidate.marker
	id := if marker.len == 24 && marker.bytes().all(it.is_hex_digit()) {
		marker
	} else {
		sha256.hexhash(server.id + ':' + candidate.path)[..24]
	}
	name := os.file_name(os.dir(candidate.path))
	profile := RemoteProfile{
		id:            id
		server_id:     server.id
		name:          name
		ssh_host:      server.ssh_host
		ssh_user:      server.ssh_user
		ssh_port:      server.ssh_port
		identity_file: server.identity_file
		auth_method:   server.auth_method
		admin_port:    port
		token:         token
		runtime_id:    candidate.runtime_id
		runtime_path:  candidate.runtime_path
		config_path:   candidate.path
	}
	profile.validate()!
	return profile
}

// The authenticated server supplies configuration and credentials. Local records
// are only a cache; existing tokens are replaced after a successful discovery.
fn merge_discovered_profiles(existing []RemoteProfile, discovered []RemoteProfile) []RemoteProfile {
	mut result := existing.clone()
	for remote in discovered {
		mut index := -1
		for i, cached in result {
			if cached.server_id == remote.server_id && (cached.config_path == remote.config_path || (cached.config_path == '' && cached.admin_port == remote.admin_port)) {
				index = i
				break
			}
		}
		if index >= 0 {
			result[index] = RemoteProfile{ ...remote, id: result[index].id }
		} else {
			id := if result.any(it.id == remote.id) {
				sha256.hexhash(remote.server_id + ':' + remote.config_path)[..24]
			} else {
				remote.id
			}
			result << RemoteProfile{ ...remote, id: id }
		}
	}
	return result
}

fn (mut s ServerSession) discover_projects() ! {
	inventory := s.shell_limited($embed_file('remote_scripts/discover.sh').to_string(), 12000, 524288)!
	mut deployments := []ApplicationDeploymentStatus{}
	mut upgrades := []RemoteRuntimeUpgrade{}
	mut candidates := map[string]RemoteProjectCandidate{}
	mut warnings := 0
	mut issues := []string{}
	for line in inventory.split_into_lines() {
		if line.starts_with('VHTTPD_DEPLOYMENT:') {
			status := json.decode[ApplicationDeploymentStatus](base64.decode_str(line.all_after(':'))) or { warnings++; continue }
			if status.id.len==24 && status.id.bytes().all(it.is_hex_digit()) && candidates.keys().contains(status.config_path) { deployments << status }
		} else if line.starts_with('VHTTPD_UPGRADE:') {
			status := json.decode[RemoteRuntimeUpgrade](base64.decode_str(line.all_after(':'))) or { warnings++; continue }
			if status.id.len == 24 && status.id.bytes().all(it.is_hex_digit()) && candidates.keys().contains(status.config_path) { upgrades << status }
		} else if line.starts_with('VHTTPD_PROJECT:') {
			parts := line.split(':')
			if parts.len != 4 {
				warnings++
				continue
			}
			path := remote_absolute_path('/', base64.decode_str(parts[1])) or {
				warnings++
				continue
			}
			binding := parts[3]
			if binding != '' && !remote_runtime_id_valid(binding) { warnings++; continue }
			candidates[path] = RemoteProjectCandidate{ path: path, marker: parts[2], runtime_id: binding }
		} else if line.starts_with('VHTTPD_RUNNING:') {
			parts := line.split(':')
			if parts.len != 4 {
				warnings++
				continue
			}
			running := running_project_candidate(base64.decode_str(parts[1]), base64.decode_str(parts[2])) or {
				if err.msg() != 'management_helper_process' { warnings++ }
				continue
			}
			old := candidates[running.path] or { RemoteProjectCandidate{} }
			executable := base64.decode_str(parts[3])
			mut binding := old.runtime_id
			for runtime in s.state.runtimes { if executable == runtime.path + '/vhttpd' && binding == '' { binding = runtime.id } }
			candidates[running.path] = RemoteProjectCandidate{ ...running, marker: old.marker, runtime_id: binding, runtime_path: executable }
		}
	}
	mut discovered := []RemoteProfile{}
	mut paths := candidates.keys()
	paths.sort()
	for path in paths {
		mut sources := map[string]string{}
		mut visiting := map[string]bool{}
		s.read_project_sources(path, mut sources, mut visiting) or {
			if err.msg().starts_with('操作已取消') {
				return error('项目同步已取消，远端服务继续运行。')
			}
			warnings++
			issues << os.file_name(os.dir(path)) + '：配置或 include 无法读取'
			continue
		}
		profile := discovered_profile(s.server, candidates[path], sources) or {
			warnings++
			issues << os.file_name(os.dir(path)) + '：无法解析 Admin 连接配置'
			continue
		}
		discovered << profile
	}
	existing := load_remote_profiles() or { return error('无法读取本机项目缓存，请检查权限或保留缓存文件后重试。') }
	merged := merge_discovered_profiles(existing, discovered)
	save_remote_profiles(merged) or { return error('无法保存本机项目缓存，请检查数据目录权限。') }
	s.state = ServerSnapshot{
		...s.state
		deployments: deployments
		upgrades:           upgrades
		projects:           discovered
		discovery_revision: s.state.discovery_revision + 1
		discovery_message:  '已从服务器同步 ${discovered.len} 个项目。' + if warnings > 0 {
			'${warnings} 个项目或进程无法自动识别。' + issues[..if issues.len > 3 {
				3
			} else {
				issues.len
			}].join('；')
		} else {
			''
		}
	}
}
