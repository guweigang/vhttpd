module main

import codex

fn test_expired_and_unknown_responses_cannot_change_current_thread() {
	mut app := &App{}
	app.providers.codex.runtime.thread_id = 'current'
	app.providers.codex.runtime.pending_rpcs[1] = codex.PendingRpc{method: 'thread/start', expires_at_ms: 1}
	for id in ['1', '999'] {
		app.codex_handle_response('main', codex.RpcClassification{is_response: true, id_raw: id},
			'{"result":{"thread":{"id":"late"}}}')
		assert app.providers.codex.runtime.thread_id == 'current'
	}
	assert app.providers.codex.runtime.pending_rpcs.len == 0
}
