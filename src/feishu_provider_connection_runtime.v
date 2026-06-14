module main

import json
import log
import net.http
import net.websocket as websock
import time
import feishu

struct FeishuRuntimeHeartbeat {}

fn FeishuRuntimeHeartbeat.loop(mut app App, instance string, ws_url string, mut client websock.Client) {
	service_id := feishu.RuntimeProtoFrame.service_id_from_ws_url(ws_url)
	if service_id <= 0 {
		return
	}
	mut interval_seconds := app.providers.feishu.ping_interval_seconds(instance)
	if interval_seconds <= 0 {
		interval_seconds = 5
	}
	for client.get_state() == .open {
		ping := feishu.RuntimeProtoFrame.client_ping(service_id)
		client.write(ping.encode(), .binary_frame) or {
			log.error('[feishu] ❌ ping send failed: ${err}')
			return
		}
		log.info('[feishu] 💓 heartbeat sent')
		if client.get_state() != .open {
			return
		}
		time.sleep(interval_seconds * time.second)
	}
}

fn (mut app App) feishu_provider_pull_ws_endpoint(app_name string) !string {
	app_cfg := app.providers.feishu.app_config(app_name)!
	body := feishu.RuntimeWsEndpointData.request_body(app_cfg.app_id, app_cfg.app_secret)
	mut last_status := 0
	mut last_error := ''
	for endpoint_url in feishu.RuntimeWsEndpointData.endpoint_urls(app.providers.feishu.open_base_url) {
		resp := (&app.providers.feishu).control_http_fetch(
			url:    endpoint_url
			method: .post
			data:   body
			header: http.new_header(key: .content_type, value: 'application/json; charset=utf-8')
		) or {
			last_error = err.msg()
			continue
		}
		last_status = resp.status_code
		if resp.status_code == 404 {
			last_error = 'status 404 at ${endpoint_url}'
			continue
		}
		if resp.status_code != 200 {
			return error('feishu ws endpoint request failed with status ${resp.status_code}')
		}
		decoded := json.decode(feishu.RuntimeWsEndpointResponse, resp.body)!
		if decoded.code != 0 || decoded.data.url.trim_space() == '' {
			detail := if decoded.msg.trim_space() != '' {
				decoded.msg
			} else {
				resp.body.trim_space()
			}
			return error('feishu ws endpoint error: code=${decoded.code} detail=${detail}')
		}
		app.providers.feishu.note_client_config(app_name, decoded.data.client_config)
		return decoded.data.url
	}
	if last_status > 0 {
		return error('feishu ws endpoint request failed with status ${last_status}')
	}
	return error('feishu ws endpoint request failed: ${last_error}')
}

fn (mut app App) feishu_runtime_tenant_access_token(app_name string) !string {
	_ := app.providers.feishu.app_config(app_name)!
	now := time.now().unix()
	app.providers.feishu.mu.@lock()
	if runtime := app.providers.feishu.runtime[app_name] {
		if runtime.tenant_access_token != ''
			&& now + i64(app.providers.feishu.token_refresh_skew_seconds) < runtime.tenant_access_token_expire_unix {
			token := runtime.tenant_access_token
			app.providers.feishu.mu.unlock()
			return token
		}
	}
	app.providers.feishu.mu.unlock()
	app_cfg := app.providers.feishu.app_config(app_name)!
	body := feishu.TenantTokenResponse.request_body(app_cfg.app_id, app_cfg.app_secret)
	resp := (&app.providers.feishu).http_fetch(
		url:    '${app.providers.feishu.open_base_url}/auth/v3/tenant_access_token/internal'
		method: .post
		data:   body
		header: http.new_header(key: .content_type, value: 'application/json; charset=utf-8')
	)!
	if resp.status_code != 200 {
		return error('feishu tenant token request failed with status ${resp.status_code}')
	}
	token, expire := feishu.TenantTokenResponse.parse(resp.body)!
	mut runtime := app.providers.feishu.ensure(app_name)
	runtime.cache_tenant_access_token(token, now + expire)
	app.providers.feishu.update_runtime(app_name, runtime)
	return token
}
