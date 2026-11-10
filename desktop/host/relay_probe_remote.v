module host

import compress.zlib
import encoding.base64
import json2 as json

// Draft credentials travel over authenticated SSH stdin, never arguments/files.
fn relay_probe_script(entry SharedRelay) !string {
	entry.validate()!
	payload := base64.encode(json.encode(entry).bytes())
	code := $embed_file('remote_scripts/relay_probe.py').to_string() + '\nprint(json.dumps(probe(json.loads(base64.b64decode("' + payload + '"))), ensure_ascii=False))\n'
	encoded := base64.encode(zlib.compress(code.bytes())!)
	script := "python3 - <<'VHTTPD_RELAY_PROBE'\nimport base64,zlib\nexec(zlib.decompress(base64.b64decode('" + encoded + "')))\nVHTTPD_RELAY_PROBE\n"
	if script.len > 16000 { return error('连接参数过长，请缩短后重试。') }
	return script
}

fn (s &ServerSession) probe_relay_draft(command ServerCommand) !RelayProbeResult {
	if !s.state.connected || s.state.busy || command.server.id != s.server.id {
		return error('请先连接目标服务器，并等待当前操作完成。')
	}
	raw := s.shell_limited(relay_probe_script(command.shared_relay)!, 12000, 4096)!
	result := json.decode[RelayProbeResult](raw) or { return error('远端测试响应无效，请重试。') }
	if result.stage !in ['网络 / DNS', 'TLS', 'WebSocket', 'Relay 认证'] || result.message.len > 1024 {
		return error('远端测试响应无效，请重试。')
	}
	return RelayProbeResult{...result, message: if command.shared_relay.token != '' {
		result.message.replace(command.shared_relay.token, '[REDACTED]')
	} else { result.message }}
}
