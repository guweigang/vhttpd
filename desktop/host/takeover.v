module host

import config
import app_bundle
import toml
import json2 as json
import net.http
import os
import time

pub struct TakeoverSelection {
pub:
	application_id string
 installation_id string
 component string
 local_engine_id string
 relay_id string
	app_id   string
	accounts []string
}

pub struct TakeoverStatus {
pub:
 binding_protocol int
	application_id string
 installation_id string
 local_in_flight int
	known           bool
	active          bool
	lease_id        string
	app_id          string
	accounts        []string
	expires_ms      i64
	checked_at      string
}

pub fn (mut m Manager) control_takeover(action string, selection TakeoverSelection) ! {
	if m.phase != .running || m.token == '' { return error('请先启动所选本地项目。') }
	if action !in ['start', 'stop', 'status'] || selection.relay_id == '' {
		return error('请选择项目中已配置的 Relay 连接。')
	}
	if action == 'start' && (selection.app_id == '' || selection.accounts.len != 1 || selection.accounts[0] == '' || selection.accounts[0].len > 128) {
		return error('请填写应用标识和一个需要接管的账号标识。')
	}
	// Stop always uses the last confirmed lease identity, never a wildcard.
	if action == 'stop' && (!m.takeover_status.known || !m.takeover_status.active || m.takeover_selection.relay_id != selection.relay_id) {
		return error('请先检查接管状态，再结束当前接管。')
	}
	body := json.encode({
		'application_id':json.Any(selection.application_id)
        'installation_id':json.Any(selection.installation_id)
        'component':json.Any(selection.component)
        'local_engine_id':json.Any(selection.local_engine_id)
        'action':   json.Any(action)
		'relay_id': json.Any(selection.relay_id)
		'route':    json.Any('debug/control')
		'app_id':   json.Any(selection.app_id)
		'accounts': json.Any(selection.accounts.map(json.Any(it)))
		'lease_id': json.Any(m.takeover_status.lease_id)
		'ttl_ms':   json.Any(900000)
	})
	mut request := http.Request{
		url:                      m.info.admin_url.replace('/admin/ui/', '/admin/runtime/takeover')
		method:                   .post
		data:                     body
		read_timeout:             7 * time.second
		write_timeout:            time.second
		max_retries:              1
		allow_redirect:           false
		disable_connection_reuse: true
	}
	request.add_custom_header('x-vhttpd-admin-token', m.token)!
	request.add_custom_header('content-type', 'application/json')!
	response := request.do() or {
		m.takeover_status = TakeoverStatus{}
		return error('接管状态未确认，请检查本地实例和 Relay 连接后重新检查。')
	}
	if response.status_code != 200 {
		m.takeover_status = TakeoverStatus{}
		return error('接管操作失败；请确认远端 debug/control 导出、本地接收入口及 Relay 已就绪，再检查状态。')
	}
	status := json.decode[TakeoverStatus](response.body)!
	m.takeover_status = TakeoverStatus{ ...status, known: true, checked_at: time.now().hhmmss() }
	m.takeover_selection = selection
	m.takeover_next_probe = time.ticks() + 5000
	m.message = if status.active {
		'指定账号的请求正在本地执行；数据库仍在远端。'
	} else {
		'接管已结束；后续请求由远端执行。'
	}
}

// A reviewable first-use draft; the receiver can only dispatch cloud function
// paths through the selected project's existing vjsx engine.
fn takeover_receiver_changeset(path string, relay_id string) !SharedRelayChangeset {
 return takeover_receiver_for_engine(path,relay_id,'')
}

fn takeover_receiver_for_engine(path string, relay_id string, selected_engine string) !SharedRelayChangeset {
	root := os.abs_path(path)
	plan := config.load_runtime_plan_file(root)!
	descriptor := plan.relays[relay_id] or { return error('项目中没有此 Relay。请先绑定远端数据库。') }
	if descriptor.mode != 'agent' || descriptor.options.strings['token'] == '' {
		return error('接收入口需要带 Token 的 agent Relay。')
	}
	for pipeline in plan.pipelines {
        if pipeline.id != 'debug/http' {continue}
        if selected_engine == '' {return error('本地接收入口已存在，请检查配置是否生效。')}
        if pipeline.ingress.str() != 'relay:' + relay_id || pipeline.egress.domain != .adapter {return error('application_binding_mismatch')}
        adapter := plan.adapters[pipeline.egress.id] or {return error('application_binding_mismatch')}
        if adapter.kind != 'debug-http' {return error('application_binding_mismatch')}
        if selected_engine !in plan.engines || plan.engines[selected_engine].kind != 'vjsx' {return error('application_binding_mismatch')}
        for source in config.runtime_config_sources(root)! {
            original := os.read_file(source.path)!
            mut data := toml.parse_text(original)!.to_any().as_map()
            mut adapters := (data['adapters'] or {toml.Any(map[string]toml.Any{})}).as_map()
            if pipeline.egress.id !in adapters {continue}
            mut item := (adapters[pipeline.egress.id] or {return error('application_binding_mismatch')}).as_map()
            item['engine']=toml.Any('engine:'+selected_engine)
            adapters[pipeline.egress.id]=toml.Any(item)
            data['adapters']=toml.Any(adapters)
            value := app_bundle.encode_config(data)!
            config.load_runtime_plan_with_overrides(root,{source.path:value})!
            return SharedRelayChangeset{config_path:root,files:[SharedRelayFile{path:source.path,original:original,value:value}]}
        }
        return error('application_binding_mismatch')
    }
	mut engine_id := selected_engine
    if selected_engine != '' && (selected_engine !in plan.engines || plan.engines[selected_engine].kind != 'vjsx') {return error('application_binding_mismatch')}
	for id, engine in plan.engines {
		if engine.kind == 'vjsx' && selected_engine == '' {
			if engine_id != '' {
				return error('项目有多个 vjsx 引擎，请在配置中指定接收引擎。')
			}
			engine_id = id
		}
	}
	if engine_id == '' || 'local_debug' in plan.adapters {
		return error('缺少唯一 vjsx 引擎或 local_debug 名称已占用。')
	}
	original := os.read_file(root)!
	value := original + '\n[adapters.local_debug]\nkind="debug-http"\nengine="engine:' + engine_id + '"\n\n[[pipelines]]\nid="debug/http"\ningress="relay:' + relay_id + '"\negress="adapter:local_debug"\n'
	config.load_runtime_plan_with_overrides(root, {
		root: value
	})!
	return SharedRelayChangeset{ config_path: root, files: [SharedRelayFile{ path: root, original: original, value: value }] }
}

pub fn (mut m Manager) prepare_takeover_receiver(selection TakeoverSelection) ! {
	if m.phase != .running || m.token == '' { return error('请先启动所选本地项目。') }
    if m.takeover_status.active {return error('请先结束本地接管，再调整接收入口。')}
	bundle := takeover_receiver_for_engine(m.project.config_path,selection.relay_id,selection.local_engine_id)!
	path := m.prepare_config_changeset_login(bundle, 'relay-takeover-')!
	open_local(path)!
	m.message = '本地接收入口草稿已打开；校验、发布并重启本地项目后可开启接管。'
}

// Prefer the configured receiver route; never bake an application's Relay ID
// into the workbench. Multiple unrelated agents require explicit selection.
pub fn project_takeover_relay(path string) string {
	plan := config.load_runtime_plan_file(path) or { return '' }
	for pipeline in plan.pipelines {
		if pipeline.id == 'debug/http' && pipeline.ingress.str().starts_with('relay:') {
			return pipeline.ingress.str().all_after('relay:')
		}
	}
	mut agents := []string{}
	for id, descriptor in plan.relays {
		if descriptor.mode == 'agent' { agents << id }
	}
	return if agents.len == 1 { agents[0] } else { '' }
}
