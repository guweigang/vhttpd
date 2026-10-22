module main

import feishu
import upstream

fn (mut app App) command_feishu_bridge_bind(claim feishu.BridgeBind) !string {
	result := app.providers.feishu_card_bridge_proxy_request_owned('bind', upstream.UpstreamSendRequest{
		provider:    'feishu'
		instance:    claim.app
		target:      claim.message
		target_type: 'message_id'
		metadata:    {
			'stream_id':           claim.stream
			'publication_id':      claim.publication_id
			'stream_generation':   claim.expected
			'source_stream':       claim.source.stream
			'source_app':          claim.source.app
			'creation_generation': claim.creation
			'creation_token':      claim.token
		}
	}, claim.source.owner)!
	return result.stream_generation
}

fn (mut app App) command_feishu_bridge_cancel_bind(claim feishu.BridgeBind, generation string) ! {
	result := app.providers.feishu_card_bridge_proxy_request_owned('clear', upstream.UpstreamSendRequest{
		provider:    'feishu'
		instance:    claim.app
		target:      claim.message
		target_type: 'message_id'
		metadata:    {
			'stream_id':         claim.stream
			'stream_generation': generation
		}
	}, claim.source.owner)!
	if !result.ok { return error('bridge_revoke_unavailable') }
}

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

fn (mut app App) command_feishu_bridge_proxy_clear(req upstream.UpstreamSendRequest, released feishu.WireStreamRelease) ! {
	if released.bridge_owner == none { return error('bridge_authority_retired') }
	mut metadata := req.metadata.clone()
	if released.bridge_generation != '' {
		metadata['stream_generation'] = released.bridge_generation
		metadata['stream_id'] = released.bridge_stream
	}
	remote := upstream.UpstreamSendRequest{
		...req
		metadata: metadata.clone()
		instance: if released.bridge_generation != '' { released.bridge_app } else { req.instance }
	}

	result := app.providers.feishu_card_bridge_proxy_request_owned('clear', remote, released.bridge_owner)!
	if !result.ok { return error('bridge_revoke_unavailable') }
}

fn (mut app App) command_feishu_bridge_stream_operation(req upstream.UpstreamSendRequest, op feishu.BridgeStreamOperation, action string) !upstream.UpstreamUpdateResult {
	if op.source.owner == none { return error('bridge_authority_retired') }
	mut metadata := req.metadata.clone()
	metadata['stream_generation'] = op.source.generation
	metadata['stream_id'] = op.source.stream
	remote := upstream.UpstreamSendRequest{ ...req, instance: op.source.app, metadata: metadata.clone() }
	result := app.providers.feishu_card_bridge_proxy_request_owned(action, remote, op.source.owner)!
	return upstream.UpstreamUpdateResult{
		ok:                result.ok
		provider:          result.provider
		instance:          result.instance
		message_id:        result.message_id
		error:             result.error
		stream_generation: result.stream_generation
		stream_state:      result.stream_state
	}
}

fn (mut app App) command_feishu_bridge_cancel_stream_operation(op feishu.BridgeStreamOperation) ! {
	if op.source.owner == none { return error('bridge_authority_retired') }
	_ := app.providers.feishu_card_bridge_proxy_request_owned('clear', upstream.UpstreamSendRequest{
		provider:    'feishu'
		instance:    op.source.app
		target:      op.buffer.message_id
		target_type: 'message_id'
		metadata:    {
			'stream_id':         op.source.stream
			'stream_generation': op.source.generation
		}
	}, op.source.owner)!
}

fn (mut app App) command_feishu_bridge_message_update(claim feishu.MessageUpdate, req upstream.UpstreamSendRequest) !upstream.UpstreamUpdateResult {
	if !app.providers.feishu.message_update_is_current(claim) {
		return error('feishu_message_update_retired')
	}
	mut request := upstream.UpstreamSendRequest{ ...req, instance: claim.source.app, metadata: req.metadata.clone() }
	request.metadata['stream_id'] = claim.source.stream
	request.metadata['stream_generation'] = claim.source.generation
	result := app.providers.feishu_card_bridge_proxy_request_owned('update', request, claim.source.owner)!
	return upstream.UpstreamUpdateResult{ ok: result.ok, provider: result.provider, instance: result.instance, message_id: result.message_id, error: result.error, stream_generation: result.stream_generation, stream_state: result.stream_state }
}
