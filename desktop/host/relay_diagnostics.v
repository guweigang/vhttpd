module host

import json2 as json
import net.http
import time

pub struct RelayLiveStatus {
pub:
	known bool
	checked_at string
	error string
	data RelayLiveData
}
pub struct RelayLiveData {
pub:
	open_channels int
	pending_frames int
	carrier_count int
	agents []RelayLiveAgent
	channels []RelayLiveChannel
	diagnostics RelayLiveDiagnostics
}
pub struct RelayLiveAgent {
pub:
	relay_id string
	state string
	attempt int
	next_attempt_at_ms i64
	last_error string
}
pub struct RelayLiveChannel {
pub:
	id string
	route string
	trace_id string
	open bool
	buffered_len int
	returned_len int
}
pub struct RelayLiveDiagnostics {
pub:
	completed u64
	failed u64
	capacity int
	events []RelayLiveEvent
}
pub struct RelayLiveEvent {
pub:
	serial u64
	at_ms i64
	kind string
	fields map[string]string
}

fn (mut m Manager) poll_relay_diagnostics() {
	if m.token == '' || time.ticks() < m.relay_next_probe { return }
	m.relay_next_probe = time.ticks() + 2000
	mut request := http.Request{url:m.info.admin_url.all_before('/admin/ui/') + '/admin/runtime/relay',
		read_timeout:300*time.millisecond,write_timeout:200*time.millisecond,max_retries:1,
		allow_redirect:false,disable_connection_reuse:true}
	request.add_custom_header('x-vhttpd-admin-token',m.token) or { return }
	response := request.do() or { m.relay_live = RelayLiveStatus{error:'连接实例失败，当前状态未确认。'}; return }
	if response.status_code != 200 {
		m.relay_live = RelayLiveStatus{error:if response.status_code == 404 { '当前运行包不支持 Relay 诊断，请更新运行包。' } else { 'Relay 诊断不可用，请检查实例连接。' }}
		return
	}
	if response.body.len > 1048576 { m.relay_live = RelayLiveStatus{error:'Relay 诊断响应过大。'}; return }
	data := json.decode[RelayLiveData](response.body) or { m.relay_live = RelayLiveStatus{error:'Relay 诊断响应无法解析。'}; return }
	m.relay_live = RelayLiveStatus{known:true,checked_at:time.now().hhmmss(),data:data}
}
