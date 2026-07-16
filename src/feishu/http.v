module feishu

import net.http
import time

// ── HTTP Test Helpers ──

pub fn (mut state FeishuState) http_test_enter() int {
	state.http_test_mu.@lock()
	state.http_test_inflight++
	state.http_test_calls++
	delay_ms := state.http_test_delay_ms
	state.http_test_mu.unlock()
	return delay_ms
}

pub fn (mut state FeishuState) http_test_leave() {
	state.http_test_mu.@lock()
	if state.http_test_inflight > 0 {
		state.http_test_inflight--
	}
	state.http_test_mu.unlock()
}

pub fn (mut state FeishuState) http_test_next_message_id() string {
	state.http_test_mu.@lock()
	state.http_test_message_seq++
	id := state.http_test_message_seq
	state.http_test_mu.unlock()
	return 'om_test_${id}'
}

pub fn (mut state FeishuState) http_test_next_reply_message_id() string {
	state.http_test_mu.@lock()
	state.http_test_message_seq++
	id := state.http_test_message_seq
	state.http_test_mu.unlock()
	return 'om_reply_${id}'
}

pub fn (mut state FeishuState) http_test_fetch(cfg http.FetchConfig) !http.Response {
	delay_ms := state.http_test_enter()
	defer {
		state.http_test_leave()
	}
	if delay_ms > 0 {
		time.sleep(time.Duration(delay_ms) * time.millisecond)
	}
	if cfg.url.contains('/auth/v3/tenant_access_token/internal') {
		return http.Response{
			status_code: 200
			body:        '{"code":0,"msg":"ok","tenant_access_token":"tenant_test_token","expire":7200}'
		}
	}
	if cfg.url.contains('/im/v1/messages/') && cfg.url.contains('/reply') {
		return http.Response{
			status_code: 200
			body:        '{"code":0,"msg":"ok","data":{"message_id":"${state.http_test_next_reply_message_id()}"}}'
		}
	}
	if cfg.url.contains('/im/v1/messages?receive_id_type=') {
		return http.Response{
			status_code: 200
			body:        '{"code":0,"msg":"ok","data":{"message_id":"${state.http_test_next_message_id()}"}}'
		}
	}
	if cfg.url.contains('/im/v1/messages/') || cfg.url.contains('/interactive/v1/card/update') {
		return http.Response{
			status_code: 200
			body:        '{"code":0,"msg":"ok","data":{"message_id":"om_updated"}}'
		}
	}
	if cfg.url.contains('/ws/v2') || cfg.url.contains('/event/v2') {
		return http.Response{
			status_code: 200
			body:        '{"code":0,"msg":"ok","data":{"url":"wss://example.test/ws","client_config":{"ReconnectInterval":5,"ReconnectNonce":1,"PingInterval":15,"ReconnectCount":0}}}'
		}
	}
	return http.Response{
		status_code: 200
		body:        '{"code":0,"msg":"ok"}'
	}
}

pub fn (mut state FeishuState) http_test_post_multipart_form(url string, _ http.PostMultipartFormConfig) !http.Response {
	delay_ms := state.http_test_enter()
	defer {
		state.http_test_leave()
	}
	if delay_ms > 0 {
		time.sleep(time.Duration(delay_ms) * time.millisecond)
	}
	if url.contains('/im/v1/images') {
		return http.Response{
			status_code: 200
			body:        '{"code":0,"msg":"ok","data":{"image_key":"img_test_1"}}'
		}
	}
	return http.Response{
		status_code: 200
		body:        '{"code":0,"msg":"ok"}'
	}
}

// ── HTTP Fetch with Lane Locking ──

pub fn (state &FeishuState) http_fetch(cfg http.FetchConfig) !http.Response {
	mut state_mut := unsafe { &FeishuState(state) }
	mut resp := http.Response{}
	mut fetch_err := ''
	lock state_mut.http_lane {
		$if test {
			if state_mut.http_test_stub {
				resp = state_mut.http_test_fetch(cfg) or {
					fetch_err = err.msg()
					http.Response{}
				}
			} else {
				resp = http.fetch(cfg) or {
					fetch_err = err.msg()
					http.Response{}
				}
			}
		} $else {
			resp = http.fetch(cfg) or {
				fetch_err = err.msg()
				http.Response{}
			}
		}
	}
	if fetch_err != '' {
		return error(fetch_err)
	}
	return resp
}

pub fn (state &FeishuState) control_http_fetch(cfg http.FetchConfig) !http.Response {
	mut state_mut := unsafe { &FeishuState(state) }
	mut resp := http.Response{}
	mut fetch_err := ''
	lock state_mut.control_http_lane {
		$if test {
			if state_mut.http_test_stub {
				resp = state_mut.http_test_fetch(cfg) or {
					fetch_err = err.msg()
					http.Response{}
				}
			} else {
				resp = http.fetch(cfg) or {
					fetch_err = err.msg()
					http.Response{}
				}
			}
		} $else {
			resp = http.fetch(cfg) or {
				fetch_err = err.msg()
				http.Response{}
			}
		}
	}
	if fetch_err != '' {
		return error(fetch_err)
	}
	return resp
}

pub fn (state &FeishuState) http_post_multipart_form(url string, cfg http.PostMultipartFormConfig) !http.Response {
	mut state_mut := unsafe { &FeishuState(state) }
	mut resp := http.Response{}
	mut fetch_err := ''
	lock state_mut.http_lane {
		$if test {
			if state_mut.http_test_stub {
				resp = state_mut.http_test_post_multipart_form(url, cfg) or {
					fetch_err = err.msg()
					http.Response{}
				}
			} else {
				resp = http.post_multipart_form(url, cfg) or {
					fetch_err = err.msg()
					http.Response{}
				}
			}
		} $else {
			resp = http.post_multipart_form(url, cfg) or {
				fetch_err = err.msg()
				http.Response{}
			}
		}
	}
	if fetch_err != '' {
		return error(fetch_err)
	}
	return resp
}
