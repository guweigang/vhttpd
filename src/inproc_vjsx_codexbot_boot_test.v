module main

import json
import os

fn codexbot_boot_test_feishu_payload(text string, chat_id string, message_id string) string {
	content_json := json.encode({
		'text': text
	})
	return '{"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","content":${json.encode(content_json)}}}}'
}

fn codexbot_boot_test_with_temp_db(db_name string, run fn (string)) {
	with_temp_sqlite_db_env('CODEXBOT_TS_DB_PATH', db_name, run)
}

fn test_inproc_vjsx_executor_repo_codexbot_app_ts_boots_in_isolation() {
	codexbot_boot_test_with_temp_db('codexbot_ts_boot_isolation.sqlite', fn (_ string) {
		app_file := os.join_path(os.dir(@FILE), '..', 'examples', 'codexbot-app-ts', 'app.mts')
		assert os.exists(app_file)
		mut executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       app_file
			module_root:     os.dir(app_file)
			runtime_profile: 'node'
		})
		defer {
			executor.close()
		}
		mut app := App{}
		resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
			mode:        'websocket_upstream'
			event:       'message'
			id:          'codexbot_ts_boot_isolation'
			provider:    'feishu'
			instance:    'main'
			trace_id:    'trace_codexbot_ts_boot_isolation'
			event_type:  'im.message.receive_v1'
			message_id:  'om_codexbot_boot_isolation'
			target:      'chat_codexbot_boot_isolation'
			target_type: 'chat_id'
			payload:     codexbot_boot_test_feishu_payload('/help', 'chat_codexbot_boot_isolation',
				'om_codexbot_boot_isolation')
			received_at: 1710001000
		}) or { panic(err) }
		assert resp.handled
		assert resp.commands.len > 0
	})
}
