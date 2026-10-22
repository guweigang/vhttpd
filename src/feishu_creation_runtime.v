module main

import upstream
import feishu
import json2 as json

// Trusted application service. Wire bind/send handlers never mint grants.
pub fn (mut app App) issue_feishu_stream_creation(stream_id string, app_name string, message_id string) !string {
	if app.providers.feishu_card_bridge_enabled() {
		issue := app.providers.feishu.begin_creation_issue_for_target(stream_id, app_name, message_id)!
		defer {
			app.providers.feishu.finish_creation_issue(issue)
			app.providers.feishu_card_bridge_rotate_creation_capacity_if_idle()
		}
		result := app.providers.feishu_card_bridge_proxy_request('create', upstream.UpstreamSendRequest{
			provider:    'feishu'
			instance:    app_name
			target:      message_id
			target_type: if message_id != '' { 'message_id' } else { '' }
			metadata:    {
				'stream_id': stream_id
			}
		})!
		if !result.ok || result.stream_generation == '' {
			return error('feishu_creation_unavailable')
		}
		lease := feishu.CreationLease{ generation: result.stream_generation, token: result.creation_token }
		app.providers.feishu.complete_bridge_creation_issue(issue, lease, result.authority) or {
			app.providers.feishu_card_bridge_proxy_request_owned('revoke_creation', upstream.UpstreamSendRequest{
				provider: 'feishu'
				instance: app_name
				metadata: {
					'stream_id':         stream_id
					'stream_generation': lease.generation
					'creation_token':    lease.token
				}
			}, result.authority) or {}
			return err
		}
		return json.encode(lease)
	}
	lease := if message_id != '' {
		app.providers.feishu.issue_wire_bind_creation(stream_id, app_name, message_id)!
	} else {
		app.providers.feishu.issue_wire_creation(stream_id, app_name)!
	}
	return json.encode(lease)
}
