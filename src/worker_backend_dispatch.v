module main

import json
import log
import time

fn (mut app App) dispatch_feishu_message_sent(stream_id string, message_id string) {
	log.info('[feishu] 📨 dispatching sent notification to PHP worker: stream_id=${stream_id} message_id=${message_id}')
	
	if app.worker_backend.sockets.len == 0 {
		log.warn('[feishu] ⚠️ no worker sockets, skipping sent notification dispatch')
		return
	}

	req := app.kernel_websocket_upstream_dispatch_request(
		'feishu-sent-${time.now().unix_milli()}',
		'feishu',
		'main',
		stream_id,
		'feishu.message.sent',
		message_id,
		'',
		'',
		json.encode({
			'stream_id':  stream_id
			'message_id': message_id
		}),
		time.now().unix(),
		map[string]string{},
	)
	
	app.kernel_dispatch_websocket_upstream(req) or {
		log.error('[feishu] ❌ failed to dispatch sent notification: ${err}')
	}
}

fn (mut app App) dispatch_feishu_message_updated(stream_id string, message_id string) {
	log.info('[feishu] 📨 dispatching update notification to PHP worker: stream_id=${stream_id} message_id=${message_id}')
	
	if app.worker_backend.sockets.len == 0 {
		log.warn('[feishu] ⚠️ no worker sockets, skipping update notification dispatch')
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
		}),
		time.now().unix(),
		map[string]string{},
	)
	
	app.kernel_dispatch_websocket_upstream(req) or {
		log.error('[feishu] ❌ failed to dispatch update notification: ${err}')
	}
}
