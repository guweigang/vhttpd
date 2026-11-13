module host

import crypto.sha256
import json2 as json
import os
import runtime_upgrade

struct DevelopmentRuntimePackage {
	id string
	selected bool
	release_tag string
}

fn development_package_paths(selected string, previous ...string) !map[string]string {
	mut paths := map[string]string{}
	mut candidates := previous.clone()
	candidates << selected
	for candidate in candidates {
		if os.is_executable(candidate) { paths['sha256-' + sha256.hexhash(os.real_path(candidate))] = os.real_path(candidate) }
	}
	root := os.join_path(workbench_data_dir(), 'runtimes')
	if !os.exists(root) { return paths }
	if os.is_link(root) { return error('invalid_runtime_package_directory') }
	children := os.ls(root)!
	if children.len > 256 { return error('runtime_package_inventory_too_large') }
	for name in children {
		if name.starts_with('.') { continue }
		dir := os.join_path(root, name)
		path := os.join_path(dir, runtime_executable_name())
		if !os.is_link(dir) && !os.is_link(path) && os.is_executable(path) {
			paths['sha256-' + sha256.hexhash(os.real_path(path))] = path
		}
	}
	return paths
}

fn development_packages(m &Manager, call DevelopmentCall, args DevelopmentArgs) !string {
	if !isnil(call.grant) { return error('local_session_required') }
	if call.tool == 'runtime_releases_list' {
		platform := if args.platform == '' { local_runtime_platform() } else { args.platform }
		if platform !in ['macos-arm64', 'linux-amd64', 'linux-arm64', 'windows-amd64'] { return error('unsupported_runtime_platform') }
		choices := runtime_catalog(platform, args.channel, args.tag, RuntimeJob{})!
		mut rows := []map[string]json.Any{}
		for choice in choices {
			rows << {
				'tag': json.Any(choice.tag)
				'channel': json.Any(choice.channel)
				'platform': json.Any(choice.platform)
				'published_at': json.Any(choice.published_at)
				'archive_bytes': json.Any(choice.archive.size)
				'checksum_available': json.Any(true)
			}
		}
		return json.encode({'source': json.Any('official_releases'), 'platform': json.Any(platform), 'releases': json.decode[json.Any](json.encode(rows))!})
	}
	paths := call.access.runtime_package_paths(call.binary)!
	if call.tool == 'runtime_packages_list' {
		mut packages := []DevelopmentRuntimePackage{}
		for id, path in paths {
			marker := os.join_path(os.dir(path), '.release-tag')
			mut tag := ''
			if os.is_file(marker) && !os.is_link(marker) && os.file_size(marker) < 256 {
				tag = os.read_file(marker)!.trim_space()
			}
			packages << DevelopmentRuntimePackage{id: id, selected: os.real_path(path) == os.real_path(call.binary), release_tag: tag}
		}
		return json.encode({'source': json.Any('desktop_package_inventory'), 'packages': json.decode[json.Any](json.encode(packages))!})
	}
	path := paths[args.package_id] or { return error('unknown_runtime_package: call runtime_packages_list') }
	info := inspect_runtime(path, '', RuntimeJob{})
	if !info.ready { return error('runtime_package_unavailable') }
	body := (RuntimeJob{}).command(path, ['--workbench-upgrade-check', m.project.config_path], 20000) or {
		return json.encode({'package_id': json.Any(args.package_id), 'version': json.Any(info.version), 'compatible': json.Any(false), 'reason': json.Any('configuration_check_failed')})
	}
	check := json.decode[runtime_upgrade.Check](body) or { return error('runtime_package_probe_protocol_unsupported') }
	if check.protocol != 1 || check.version != info.version || check.revision != runtime_upgrade.revision(m.project.config_path)! {
		return error('runtime_package_probe_protocol_mismatch')
	}
	return json.encode({'package_id': json.Any(args.package_id), 'version': json.Any(info.version), 'compatible': json.Any(true), 'source': json.Any('runtime_package')})
}

fn (a &DevelopmentAccess) runtime_package_paths(selected string) !map[string]string {
 a.mu.@lock()
 previous := a.runtime_paths.clone()
 a.mu.unlock()
 return development_package_paths(selected, ...previous)!
}
