module host

import json2
import net.http
import time

fn (mut m Manager) reset_log_focus() {
	m.log_filter = ''
	m.log_focus_serial = 0
	m.next_log_probe = 0
	m.request_logs.clear()
	m.request_log_ids.clear()
}

// Keep only the structured completion record, never nearby arbitrary log lines.
fn (mut m Manager) capture_request_log(line string) {
	marker := '[http.observation] '
	if !line.contains(marker) || line.len > 1600 { return }
	fields := json2.decode[map[string]string](line.all_after(marker)) or { return }
	id := fields['observation_id']
	if !id.starts_with('http-') || id.len > 40 || id.len < 6 || !id[5..].bytes().all(it.is_digit()) { return }
	mut safe := map[string]string{}
	for key in ['observation_id','listener','pipeline','method','status','duration_ms','at_unix','queue_ms','vjsx_ms','adapter_ms','other_ms','queue_observed','vjsx_observed','adapter_observed','stages_available'] { safe[key] = fields[key] }
	if id !in m.request_logs { m.request_log_ids << id }
	m.request_logs[id] = marker + json2.encode(safe,escape_unicode:true)
	if m.request_log_ids.len > 1000 {
		m.request_logs.delete(m.request_log_ids[0])
		m.request_log_ids = m.request_log_ids[1..].clone()
	}
}

fn (m &Manager) visible_logs() string {
	if m.log_filter == '' { return m.lines.join('\n') }
	line := m.request_logs[m.log_filter] or { return '未找到此请求的本地完成日志，可能已清空或超出最近 1000 条保留范围。' }
	fields := json2.decode[map[string]string](line.all_after('[http.observation] ')) or { return line }
	if fields['stages_available'] != 'true' { return line }
	mut labels := []string{}
	for key in ['queue','vjsx','adapter','other'] {
		name := match key { 'queue' { '排队' } 'vjsx' { 'vjsx 执行' } 'adapter' { '出口 Adapter' } else { '其他处理' } }
		value := if key == 'other' || fields[key+'_observed'] == 'true' { fields[key+'_ms']+' ms' } else { '未经过或未采集' }
		labels << name+'：'+value
	}
	return labels.join(' · ')+'\n'+line
}

fn (mut m Manager) poll_log_focus() {
	now := time.ticks()
	if now < m.next_log_probe || m.token == '' { return }
	m.next_log_probe = now + 1000
	origin := m.info.admin_url.all_before('/admin/ui/')
	mut request := http.Request{url:'${origin}/admin/workbench/log-focus',read_timeout:200*time.millisecond,write_timeout:200*time.millisecond,max_retries:1,allow_redirect:false,disable_connection_reuse:true}
	request.add_custom_header('x-vhttpd-admin-token',m.token) or { return }
	response := request.do() or { return }
	if response.status_code != 200 { return }
	focus := json2.decode[LogFocus](response.body) or { return }
	if focus.serial <= m.log_focus_serial || focus.at_unix < time.now().unix()-30 || !focus.observation_id.starts_with('http-') || focus.observation_id.len > 40 || focus.observation_id.len < 6 || !focus.observation_id[5..].bytes().all(it.is_digit()) { return }
	m.log_focus_serial = focus.serial
	m.log_filter = focus.observation_id
}

struct LogFocus {
	serial u64
	observation_id string
	at_unix i64
}
