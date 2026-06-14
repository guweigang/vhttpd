module main

import upstream
import feishu

fn (mut app App) websocket_upstream_provider_send(provider string, req upstream.UpstreamSendRequest) !upstream.UpstreamSendResult {
	return match provider {
		websocket_upstream_provider_feishu {
			if app.feishu_card_bridge_enabled() {
				return app.feishu_card_bridge_proxy_send(req)
			}
			result :=
				app.feishu_runtime_send_message(feishu.SendMessageRequest.from_upstream_request(req))!
			return result.to_upstream_send_result(provider,
				app.providers.feishu.resolve_app_name(req.instance)!)
		}
		websocket_upstream_provider_fixture {
			result := app.transport.websocket.fixture_send(req.instance)
			return upstream.UpstreamSendResult{
				ok:         result.ok
				provider:   result.provider
				instance:   result.instance
				message_id: result.message_id
				error:      result.error
			}
		}
		websocket_upstream_provider_codex {
			return app.codex_provider_send(req)
		}
		else {
			return error('unknown websocket upstream provider ${provider}')
		}
	}
}

fn (mut app App) websocket_upstream_provider_update(provider string, req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	return match provider {
		websocket_upstream_provider_feishu {
			if app.feishu_card_bridge_enabled() {
				return app.feishu_card_bridge_proxy_update(req)
			}
			result :=
				app.feishu_runtime_update_message(feishu.UpdateMessageRequest.from_upstream_request(req))!
			return result.to_upstream_update_result(provider,
				app.providers.feishu.resolve_app_name(req.instance)!)
		}
		websocket_upstream_provider_fixture {
			result := app.transport.websocket.fixture_update_msg(req.instance, req.target)!
			return upstream.UpstreamUpdateResult{
				ok:         result.ok
				provider:   result.provider
				instance:   result.instance
				message_id: result.message_id
				error:      result.error
			}
		}
		websocket_upstream_provider_codex {
			return app.codex_provider_update(req)
		}
		else {
			return error('unknown websocket upstream provider ${provider}')
		}
	}
}

fn (mut app App) websocket_upstream_send(req upstream.UpstreamSendRequest) !upstream.UpstreamSendResult {
	normalized := req.normalized('feishu')
	return app.websocket_upstream_provider_send(normalized.provider, normalized)
}

fn (mut app App) websocket_upstream_update(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	normalized := req.normalized('feishu')
	return app.websocket_upstream_provider_update(normalized.provider, normalized)
}
