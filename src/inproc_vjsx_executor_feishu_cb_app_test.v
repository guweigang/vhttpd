module main

import os

fn feishu_cb_app_file() string {
	return os.real_path(os.join_path(os.dir(@FILE), '..', 'examples', 'feishu_cb-app-ts', 'app.mts'))
}

fn feishu_cb_new_executor() InProcVjsxExecutor {
	app_file := feishu_cb_app_file()
	assert os.exists(app_file)
	return new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     os.dir(app_file)
		build_root:      os.join_path(os.temp_dir(), 'vhttpd_feishu_cb_test_cache')
		runtime_profile: 'node'
		enable_fs:       false
	})
}

fn test_inproc_vjsx_executor_feishu_cb_app_handles_card_action() {
	mut executor := feishu_cb_new_executor()
	defer {
		executor.close()
	}
	mut app := App{}
	resp := executor.dispatch_websocket_upstream(mut app, WorkerWebSocketUpstreamDispatchRequest{
		mode:        'websocket_upstream'
		event:       'action'
		id:          'req_feishu_cb_action'
		provider:    'feishu'
		instance:    'main'
		trace_id:    'trace_feishu_cb_action'
		event_type:  'card.action.trigger'
		target:      'om_card_demo'
		target_type: 'open_message_id'
		payload:     '{"header":{"event_id":"evt_demo","event_type":"card.action.trigger"},"action":{"tag":"button","value":{"kind":"codex_approval","requestId":"approve-demo","decision":"accept"}},"operator":{"open_id":"ou_demo"},"context":{"open_message_id":"om_card_demo"}}'
	}) or {
		panic(err)
	}
	assert resp.handled
	assert resp.status == 200
	assert resp.headers['content-type'] == 'application/json; charset=utf-8'
	assert resp.body.contains('Card Action Forwarded')
	assert resp.body.contains('approve-demo')
}
