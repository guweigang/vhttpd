module main

import config
import feishu
import provider
import net
import time

fn credential_owner_app() &App {
	return &App{
		providers: ProviderRuntimeHub{
			feishu: feishu.FeishuState{
				apps:           {
					'main': config.FeishuAppConfig{ app_id: 'old-id', app_secret: 'old-secret' }
				}
				http_test_stub: true
				open_base_url:  'https://open.feishu.test/open-apis'
			}
		}
	}
}

fn credential_owner_configure(mut app App, id string, secret string) {
	prepared := prepare_provider_instance(provider.ProviderInstanceSpec{
		provider:    'feishu'
		instance:    'main'
		config_json: '{"app_id":"${id}","app_secret":"${secret}"}'
	}) or { panic(err) }
	app.mu.@lock()
	app.apply_provider_instance_unlocked(prepared)
	app.mu.unlock()
}

fn test_feishu_credential_rotation_invalidates_cached_token_and_preserves_activity() {
	for change_id in [false, true] {
		mut app := credential_owner_app()
		app.providers.feishu.cache_tenant_access_token('main', 'old-token', time.now().unix() + 7200)
		app.providers.feishu.note_frame('main')
		app.providers.feishu.push_event('main', feishu.RuntimeEventSnapshot{ event_id: 'keep' })
		credential_owner_configure(mut app, if change_id { 'new-id' } else { 'old-id' }, if change_id {
			'old-secret'
		} else {
			'new-secret'
		})
		token := app.providers.feishu_runtime_tenant_access_token('main') or { panic(err) }
		assert token == 'tenant_test_token'
		assert app.providers.feishu.http_test_calls == 1
		live := app.providers.feishu.ensure('main')
		assert live.received_frames == 1
		assert live.recent_events[0].event_id == 'keep'
	}
}

fn test_feishu_refresh_from_retired_credentials_is_rejected() {
	mut app := credential_owner_app()
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	address := listener.addr() or { panic(err) }
	app.providers.feishu.open_base_url = 'http://${address}'
	app.providers.feishu.http_test_stub = false
	ready := chan bool{cap: 1}
	release := chan bool{cap: 1}
	server := spawn fn [mut listener, ready, release] () {
		defer { listener.close() or {} }
		mut conn := listener.accept() or { panic(err) }
		defer { conn.close() or {} }
		conn.set_read_timeout(5 * time.second)
		expected := feishu.TenantTokenResponse.request_body('old-id', 'old-secret')
		mut request := ''
		mut buffer := []u8{len: 4096}
		for !request.contains('\r\n\r\n${expected}') {
			n := conn.read(mut buffer) or { panic(err) }
			assert n > 0
			request += buffer[..n].bytestr()
		}
		ready <- true
		select {
			_ := <-release {
			}
			5 * time.second {
				panic('credential response was not released')
			}
		}
		body := '{"code":0,"tenant_access_token":"retired-token","expire":7200}'
		conn.write_string('HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: ${body.len}\r\n\r\n${body}') or { panic(err) }
	}()
	result := chan string{cap: 1}
	spawn fn [mut app, result] () {
		token := app.providers.feishu_runtime_tenant_access_token('main') or {
			result <- 'error:${err}'
			return
		}
		result <- token
	}()
	select {
		_ := <-ready {
		}
		5 * time.second {
			panic('credential request did not reach the origin')
		}
	}
	credential_owner_configure(mut app, 'new-id', 'new-secret')
	release <- true
	select {
		got := <-result {
			assert got == 'error:feishu tenant token credentials changed'
		}
		5 * time.second {
			panic('refresh did not finish')
		}
	}
	server.wait()
	assert app.providers.feishu.ensure('main').tenant_access_token == ''
	app.providers.feishu.http_test_stub = true
	assert app.providers.feishu_runtime_tenant_access_token('main') or { panic(err) } == 'tenant_test_token'
}

fn test_feishu_identical_credentials_preserve_cache_and_refresh_authority() {
	mut app := credential_owner_app()
	now := time.now().unix()
	request := app.providers.feishu.begin_tenant_token_request('main', now) or { panic(err) }
	app.providers.feishu.cache_tenant_access_token('main', 'valid-token', now + 7200)
	credential_owner_configure(mut app, 'old-id', 'old-secret')
	assert app.providers.feishu_runtime_tenant_access_token('main') or { panic(err) } == 'valid-token'
	assert app.providers.feishu.http_test_calls == 0
	assert app.providers.feishu.commit_tenant_token_request(request, 'refreshed', now + 7200)
	assert app.providers.feishu.ensure('main').tenant_access_token == 'refreshed'
}

fn test_feishu_credential_aba_cannot_revive_retired_refresh() {
	mut app := credential_owner_app()
	now := time.now().unix()
	request := app.providers.feishu.begin_tenant_token_request('main', now) or { panic(err) }
	credential_owner_configure(mut app, 'new-id', 'new-secret')
	credential_owner_configure(mut app, 'old-id', 'old-secret')
	current := app.providers.feishu.begin_tenant_token_request('main', now) or { panic(err) }
	assert app.providers.feishu.commit_tenant_token_request(current, 'current', now + 7200)
	assert !app.providers.feishu.commit_tenant_token_request(request, 'retired', now + 7200)
	assert app.providers.feishu.ensure('main').tenant_access_token == 'current'
}

fn test_feishu_refresh_authority_is_scoped_to_its_state_and_app() {
	mut one := credential_owner_app()
	mut two := credential_owner_app()
	now := time.now().unix()
	request := one.providers.feishu.begin_tenant_token_request('main', now) or { panic(err) }
	_ := two.providers.feishu.begin_tenant_token_request('main', now) or { panic(err) }
	assert !two.providers.feishu.commit_tenant_token_request(request, 'foreign', now + 7200)
	one.providers.feishu.configure_app('other', config.FeishuAppConfig{ app_id: 'other', app_secret: 'other' })
	one.providers.feishu.note_frame('main')
	one.providers.feishu.note_send('main', true)
	assert one.providers.feishu.commit_tenant_token_request(request, 'valid', now + 7200)
	assert one.providers.feishu.ensure('other').tenant_access_token == ''
	assert one.providers.feishu.ensure('main').received_frames == 1
	assert one.providers.feishu.ensure('main').messages_sent == 1
}

fn test_feishu_default_app_cache_and_expiry_skew_use_the_same_owner() {
	mut app := credential_owner_app()
	app.providers.feishu.token_refresh_skew_seconds = 30
	assert app.providers.feishu_runtime_tenant_access_token('') or { panic(err) } == 'tenant_test_token'
	assert app.providers.feishu_runtime_tenant_access_token('main') or { panic(err) } == 'tenant_test_token'
	assert app.providers.feishu.http_test_calls == 1
	assert app.providers.feishu.ensure('').tenant_access_token == ''
	app.providers.feishu.cache_tenant_access_token('main', 'expiring', time.now().unix() + 10)
	assert app.providers.feishu_runtime_tenant_access_token('main') or { panic(err) } == 'tenant_test_token'
	assert app.providers.feishu.http_test_calls == 2
	if _ := app.providers.feishu_runtime_tenant_access_token('missing') {
		assert false
	} else {
		assert err.msg() == 'unknown feishu app "missing"'
	}
	assert app.providers.feishu.http_test_calls == 2
}
