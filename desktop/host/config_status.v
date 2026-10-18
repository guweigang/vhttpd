module host

import json2
import net.http
import net.urllib
import time

pub enum ConfigState {
	unknown
	checking
	effective
	pending
	unavailable
}

pub struct ConfigStatus {
pub:
	state ConfigState
	message string
	checked_at string
	strategy string
	recovery_available bool
	pending bool
	affected_sources []ConfigFileDiff
	fields []ConfigFieldDiff
	files []ConfigFileDiff
	relays []string
	pipelines []string
}

// Only query the authenticated instance owned by this manager. A transport,
// validation or authentication failure must never clear a pending indication.
fn check_config_status(admin_url string, token string, config_path string) ConfigStatus {
	mut request := http.Request{
		url: admin_url.replace('/admin/ui/', '/admin/runtime/plan/replacement') + '?config=' + urllib.query_escape(config_path)
		read_timeout: 600 * time.millisecond
		write_timeout: 600 * time.millisecond
		max_retries: 1
		allow_redirect: false
		disable_connection_reuse: true
	}
	request.add_custom_header('x-vhttpd-admin-token', token) or { return unavailable_config() }
	response := request.do() or { return unavailable_config() }
	if response.status_code != 200 { return unavailable_config() }
	return decode_config_status(response.body, config_path) or { unavailable_config() }
}

fn unavailable_config() ConfigStatus {
	return ConfigStatus{state: .unavailable, message: '生效检查失败，请检查管理接口或项目配置；稍后自动重试。', checked_at: time.now().hhmmss()}
}

fn decode_config_status(body string, config_path string) !ConfigStatus {
	value := json2.decode[json2.Any](body)!
	obj := value.as_map()
	allowed := obj['allowed'] or { return error('missing allowed') }
	actions := obj['actions'] or { return error('missing actions') }
	path := obj['config_path'] or { return error('missing config_path') }
	strategy := obj['strategy'] or { return error('missing strategy') }
	if allowed !is bool || actions !is []json2.Any || path !is string || strategy !is string {
		return error('invalid preview')
	}
	if path.str() != config_path || strategy.str() == '' { return error('wrong project') }
	if allowed.bool() && actions.as_array().len == 0 {
		return ConfigStatus{state: .effective, message: '项目配置已生效', checked_at: time.now().hhmmss()}
	}
	mut changes := []string{}
	for key, title in {'reload_relays': 'Relay', 'changed_pipelines': 'Pipeline', 'restart_listeners': 'Listener', 'drain_engines': 'Engine'} {
		items := obj[key] or { continue }
		ids := items.as_array().map(it.str())
		if ids.len > 0 { changes << '${title}: ${ids.join(", ")}' }
	}
	return ConfigStatus{
		state: .pending
		pending: true
		message: '配置尚未生效 · 请重启项目' + if changes.len > 0 { '\n' + changes.join(' · ') } else { '' }
		checked_at: time.now().hhmmss()
		relays: (obj['reload_relays'] or { json2.Any([]json2.Any{}) }).as_array().map(it.str())
		pipelines: (obj['changed_pipelines'] or { json2.Any([]json2.Any{}) }).as_array().map(it.str())
		strategy: strategy.str()
	}
}

pub fn (mut m Manager) refresh_config_status() {
	if m.phase != .running || isnil(m.process) { return }
	previous := m.config_status
	m.next_config_probe = time.ticks() + 2000
	current := config_revisions(m.project.config_path) or {
		m.config_status = failed_config_status(previous)
		return
	}
	recovery := recovery_sources(current) or { []RecoverySource{} }
	fields := config_component_fields(m.project.config_path, current, m.field_salt) or {
		m.config_status = failed_config_status(previous)
		return
	}
	mut status := check_config_status(m.info.admin_url, m.token, m.project.config_path)
	after := config_revisions(m.project.config_path) or {
		m.config_status = failed_config_status(previous)
		return
	}
	if status.state == .unavailable || current != after {
		m.config_status = failed_config_status(previous)
		return
	}
	if status.pending {
		files := config_file_diffs(m.config_baseline, current)
		mut affected := []ConfigFileDiff{}
		for source in affected_config_sources(m.config_baseline, current, status.relays, status.pipelines) {
			if !files.any(it.path == source.path) { affected << source }
		}
		status = ConfigStatus{...status, files: files, affected_sources: affected, fields: config_field_diffs(m.field_baseline, fields)}
	} else if status.state == .effective {
		m.config_baseline = current
		m.field_baseline = fields
		if recovery.len == current.len {
			m.record_recovery_baseline(current, recovery, m.recovery_store_root)
		}
	}
	if m.recovery_notice != '' { status = ConfigStatus{...status, message: status.message + '\n' + m.recovery_notice} }
	m.config_status = ConfigStatus{...status, recovery_available: m.recovery_confirmed}
}

fn failed_config_status(previous ConfigStatus) ConfigStatus {
	failed := unavailable_config()
	return ConfigStatus{...failed, recovery_available: previous.recovery_available, pending: previous.pending, fields: previous.fields, files: previous.files, affected_sources: previous.affected_sources, relays: previous.relays, pipelines: previous.pipelines,
		message: if previous.pending { '上次检查：配置尚未生效。' + failed.message } else { failed.message }}
}
