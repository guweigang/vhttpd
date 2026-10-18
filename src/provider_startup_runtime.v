module main

import log

struct ProviderStartupRuntime {}

fn ProviderStartupRuntime.initialize(mut app App) {
	app.providers.feishu_card_bridge_apply_env_fallbacks()
	ProviderStartupRuntime.start_feishu_background(mut app)
	app.bootstrap_providers()
	relay_agents_started := app.start_relay_agents_once('relay-agent-startup')
	if relay_agents_started > 0 {
		log.info('[vhttpd] Relay Agents: started ${relay_agents_started}')
	}
}

fn ProviderStartupRuntime.start_feishu_background(mut app App) {
	if app.providers.feishu.enabled {
		if mut run := app.providers.feishu.background_runs.reserve('buffer-flusher') {
			go app.feishu_runtime_run_buffer_flusher(mut run)
		}
	}
	if app.providers.feishu_card_bridge_enabled() { FeishuCardBridgeRuntime.start_client(mut app) }
}

fn ProviderStartupRuntime.start_upstreams(mut app App) {
	mut upstream_launches := app.provider_runtime_upstream_launches()
	mut feishu_labels := []string{}
	mut started_any_upstream := false
	for launch in upstream_launches {
		if launch.instance == '' {
			if launch.provider == 'feishu' && launch.label != '' {
				feishu_labels = launch.label.split(', ').clone()
			}
			continue
		}
		if launch.provider == 'codex' && app.logic_executor_kind() == 'vjsx' {
			log.info('[vhttpd] WebSocket Upstream: codex deferred to vjsx app_startup (${launch.label})')
			continue
		}
		started_any_upstream = true
		_ = app.ensure_websocket_upstream_provider_running(launch.provider, launch.instance)
		if launch.provider == 'codex' {
			log.info('[vhttpd] WebSocket Upstream: codex enabled (${launch.url})')
		}
	}
	if feishu_labels.len > 0 {
		log.info('[vhttpd] WebSocket Upstream: feishu enabled (${feishu_labels.join(', ')})')
	}
	if !started_any_upstream {
		log.info('[vhttpd] WebSocket Upstream: disabled')
	}
}
