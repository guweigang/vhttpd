module host

import config
import net.urllib
import crypto.rand
import json2
import net.http
import os
import time

struct BrowserHandoff {
	path    string
	expires i64
}

// The file contains only a short-lived, single-use ticket, never the Admin token.
// POST keeps even that ticket out of browser history, URLs and Referer headers.
fn login_document(action string, ticket string) string {
	return '<!doctype html><html><head><meta charset="utf-8"><meta name="referrer" content="no-referrer"><title>正在登录 vhttpd Admin</title></head><body><p>正在打开 Admin UI…</p><form method="post" action="${action.replace('&', '&amp;')}"><input type="hidden" name="ticket" value="${ticket}"><button type="submit">打开 Admin UI</button></form><script>document.forms[0].submit()</script></body></html>'
}

pub fn (mut m Manager) prepare_browser_login() !string {
	return m.prepare_browser_login_target('')
}

pub fn (mut m Manager) prepare_config_login(source string) !string {
	if m.phase != .running || m.token == '' { return error('请先启动项目。') }
	files := config.runtime_config_sources(m.project.config_path)!
	if !files.any(it.path == source) { return error('此来源已不属于当前项目，请重新检查配置差异。') }
	fragment := '#config-source?project=' + urllib.query_escape(m.project.config_path) + '&source=' + urllib.query_escape(source)
	return m.prepare_browser_login_target(fragment)
}

fn (mut m Manager) prepare_browser_login_target(fragment string) !string {
	if m.phase != .running || m.token == '' { return error('请先启动项目。') }
	origin := m.info.admin_url.all_before('/admin/ui/')
	mut request := http.Request{
		method:                   .post
		url:                      '${origin}/admin/auth/handoff'
		read_timeout:             2 * time.second
		write_timeout:            2 * time.second
		max_retries:              1
		allow_redirect:           false
		disable_connection_reuse: true
	}
	request.add_custom_header('x-vhttpd-admin-token', m.token)!
	response := request.do() or { return error('无法建立浏览器登录，请确认管理服务仍在运行。') }
	if response.status_code != 200 {
		return error('浏览器自动登录不可用，请更新 vhttpd 后重新启动项目。')
	}
	body := json2.decode[map[string]string](response.body) or { return error('管理服务返回了无效的登录交接。') }
	ticket := body['ticket']
	if ticket.len != 64 || !ticket.bytes().all(it.is_hex_digit()) {
		return error('管理服务返回了无效的登录票据。')
	}
	name := rand.bytes(16)!.hex()
	path := os.join_path(os.temp_dir(), 'vhttpd-login-${name}.html')
	fd := create_project_file(path)!
	write_project_contents(fd, login_document('${origin}/admin/auth/exchange${fragment}', ticket)) or {
		os.rm(path) or {}
		return err
	}
	m.browser_handoffs << BrowserHandoff{ path: path, expires: time.ticks() + 35000 }
	return path
}

pub fn (mut m Manager) open_admin() ! {
	path := m.prepare_browser_login()!
	open_local(path)!
	m.message = '已打开浏览器并自动登录 Admin UI。'
}

fn (mut m Manager) cleanup_browser_handoffs(all bool) {
	mut keep := []BrowserHandoff{}
	for file in m.browser_handoffs {
		if all || file.expires <= time.ticks() {
			os.rm(file.path) or {}
		} else {
			keep << file
		}
	}
	m.browser_handoffs = keep
}

pub fn (mut m Manager) open_config(source string) ! {
	path := m.prepare_config_login(source)!
	open_local(path)!
	m.message = '已打开 Admin UI 对应配置来源。'
}
