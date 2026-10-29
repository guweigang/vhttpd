module host

import config
import net.urllib
import os

pub struct ProjectRelayInfo {
pub:
	id        string
	mode      string
	carrier   string
	endpoint  string
	node_id   string
	autostart bool
	pipelines []string
}

pub struct ProjectDetails {
pub:
	entry     string
	sources   []string
	listeners []string
	pipelines []string
	relays    []ProjectRelayInfo
}

// Read the same compiled plan used by vhttpd, including v1 compatibility and
// includes. No second relay configuration or implicit runtime override is stored.
pub fn project_details(project Project) !ProjectDetails {
	plan := config.load_runtime_plan_file(project.config_path)!
	mut sources := []string{}
	mut entry := ''
	mut engine_ids := plan.engines.keys()
	engine_ids.sort()
	for id in engine_ids {
		engine := plan.engines[id]
		path := engine.options.strings['app_entry'] or { engine.options.strings['entry'] or { '' } }
		if path != '' {
			sources << '${id} (${engine.kind}) → ${path}'
			if entry == '' { entry = path }
		}
	}
	mut listeners := []string{}
	mut listener_ids := plan.listeners.keys()
	listener_ids.sort()
	for id in listener_ids {
		listener := plan.listeners[id]
		listeners << '${id} · ${listener.protocol}/${listener.transport} · ${url_host(listener.host)}:${listener.port}'
	}
	mut pipelines := []string{}
	for pipeline in plan.pipelines {
		pipelines << '${pipeline.id}: ${pipeline.ingress.str()} → ${pipeline.egress.str()}'
	}
	mut relays := []ProjectRelayInfo{}
	mut relay_ids := plan.relays.keys()
	relay_ids.sort()
	for id in relay_ids {
		relay := plan.relays[id]
		mut endpoint := safe_relay_endpoint(relay.options.strings['url'])
		if ingress := relay.ingress {
			if listener := plan.listeners[ingress.id] {
				scheme := if listener.tls.enabled { 'wss' } else { 'ws' }
				endpoint = '${scheme}://${url_host(listener.host)}:${listener.port}${relay.options.strings['path']}'
			}
		}
		secret := relay.options.strings['token']
		if secret != '' { endpoint = endpoint.replace(secret, '[REDACTED]') }
		mut bindings := []string{}
		for pipeline in plan.pipelines {
			mut bound := pipeline.ingress.domain == .relay && pipeline.ingress.id == id
			if pipeline.egress.domain == .adapter {
				if adapter := plan.adapters[pipeline.egress.id] {
					bound = bound || (adapter.kind == 'relay-delivery' && adapter.options.strings['target'] == 'relay:${id}')
				}
			}
			if bound {
				bindings << '${pipeline.id}: ${pipeline.ingress.str()} → ${pipeline.egress.str()}'
			}
		}
		relays << ProjectRelayInfo{
			id:        id
			mode:      if relay.mode == '' { 'hub' } else { relay.mode }
			carrier:   if relay.carrier == '' { 'websocket' } else { relay.carrier }
			endpoint:  endpoint
			node_id:   relay.options.strings['node_id']
			autostart: relay.options.bools['autostart']
			pipelines: bindings
		}
	}
	return ProjectDetails{ entry: entry, sources: sources, listeners: listeners, pipelines: pipelines, relays: relays }
}

fn safe_relay_endpoint(raw string) string {
	if raw == '' { return '未设置连接地址' }
	url := urllib.parse(raw) or { return '地址格式无效（已隐藏）' }
	// User info, query parameters and fragments may carry credentials.
	return '${url.scheme}://${url.host}${url.escaped_path()}'
}

pub fn open_text_file(path string) ! {
	if !os.is_file(path) { return error('文件不存在，请检查配置中的入口路径。') }
	$if macos {
		mut process := os.new_process('/usr/bin/open')
		process.set_args(['-t', os.real_path(path)])
		process.run()
		process.wait()
		defer { process.close() }
		if process.code != 0 { return error('系统文本编辑器无法打开文件。') }
	} $else $if linux {
		open_local(os.real_path(path))!
	} $else {
		return error('当前平台尚未实现外部编辑器入口。')
	}
}
