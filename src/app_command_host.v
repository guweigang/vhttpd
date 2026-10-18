module main

import feishu
import upstream

fn (mut app App) command_feishu_state() &feishu.FeishuState { return &app.providers.feishu }

fn (mut app App) command_feishu_bridge_enabled() bool {
	return app.providers.feishu_card_bridge_enabled()
}

fn (mut app App) command_feishu_bridge_proxy_append(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	return app.providers.feishu_card_bridge_proxy_append(req)
}

fn (mut app App) command_feishu_bridge_proxy_finish(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	return app.providers.feishu_card_bridge_proxy_finish(req)
}

fn (mut app App) command_feishu_bridge_proxy_fail(req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	return app.providers.feishu_card_bridge_proxy_fail(req)
}
