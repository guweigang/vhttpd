module main

import json2 as json
import log
import time
import feishu

fn (mut app App) dispatch_feishu_message_sent(receipt feishu.SentReceipt) {
	if receipt.stream_id == '' || receipt.message_id == '' { return }
	if !app.has_websocket_upstream_logic_executor() { return }
	req := app.kernel_websocket_upstream_dispatch_request(
		'feishu-sent-${time.now().unix_milli()}', 'feishu', receipt.instance,
		receipt.stream_id, 'feishu.message.sent', receipt.message_id, '', '',
		json.encode(receipt, escape_unicode: true, time_as_unix: true),
		time.now().unix(), map[string]string{},
	)
	app.kernel_dispatch_websocket_upstream(req) or {
		log.error('[feishu] failed to dispatch sent notification: ${err}')
	}
}

fn (mut app App) dispatch_feishu_message_updated(stream_id string, message_id string) {
	log.info('[feishu] 📨 dispatching update notification to logic executor kind=${app.logic_executor_kind()}: stream_id=${stream_id} message_id=${message_id}')

	if !app.has_websocket_upstream_logic_executor() {
		log.warn('[feishu] ⚠️ websocket_upstream logic executor unavailable, skipping update notification dispatch')
		return
	}

	req := app.kernel_websocket_upstream_dispatch_request(
		'feishu-update-${time.now().unix_milli()}',
		'feishu',
		'main',
		stream_id,
		'feishu.message.updated',
		message_id,
		'',
		'',
		json.encode({
			'stream_id':  stream_id
			'message_id': message_id
		}, escape_unicode: true, time_as_unix: true),
		time.now().unix(),
		map[string]string{},
	)

	app.kernel_dispatch_websocket_upstream(req) or {
		log.error('[feishu] ❌ failed to dispatch update notification: ${err}')
	}
}
