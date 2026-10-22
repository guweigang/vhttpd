module main

import json2 as json
import log
import net.http
import net.websocket as websock
import time
import feishu
import connection_runtime

struct FeishuRuntimeHeartbeat {}

fn FeishuRuntimeHeartbeat.loop(state &feishu.FeishuState, instance string, ws_url string, mut session connection_runtime.Session, mut client websock.Client) {
	service_id := feishu.RuntimeProtoFrame.service_id_from_ws_url(ws_url)
	if service_id <= 0 {
		return
	}
	mut interval_seconds := state.ping_interval_seconds(instance)
	if interval_seconds <= 0 {
		interval_seconds = 5
	}
	for !session.stopped() && client.get_state() == .open {
		ping := feishu.RuntimeProtoFrame.client_ping(service_id)
		client.write(ping.encode(), .binary_frame) or {
			log.error('[feishu] ❌ ping send failed: ${err}')
			session.note_reason('heartbeat:${err}')
			session.request_stop()
			return
		}
		log.info('[feishu] 💓 heartbeat sent')
		if client.get_state() != .open {
			return
		}
		if !session.wait(interval_seconds * time.second) { return }
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
		decoded := json.decode[feishu.RuntimeWsEndpointResponse](resp.body)!
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

fn (mut hub ProviderRuntimeHub) feishu_runtime_tenant_access_token(app_name string) !string {
	now := time.now().unix()
	request := hub.feishu.begin_tenant_token_request(app_name, now)!
	if request.cached_token != '' {
		return request.cached_token
	}
	body := feishu.TenantTokenResponse.request_body(request.app_id, request.app_secret)
	resp := (&hub.feishu).http_fetch(
		url:    '${hub.feishu.open_base_url}/auth/v3/tenant_access_token/internal'
		method: .post
		data:   body
		header: http.new_header(key: .content_type, value: 'application/json; charset=utf-8')
	)!
	if resp.status_code != 200 {
		return error('feishu tenant token request failed with status ${resp.status_code}')
	}
	token, expire := feishu.TenantTokenResponse.parse(resp.body)!
	if !hub.feishu.commit_tenant_token_request(request, token, now + expire) {
		return error('feishu tenant token credentials changed')
	}
	return token
}
