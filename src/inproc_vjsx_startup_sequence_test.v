module main

import json
import os

fn startup_sequence_feishu_payload(text string, chat_id string, message_id string) string {
	content_json := json.encode({
		'text': text
	})
	return '{"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","content":${json.encode(content_json)}}}}'
}

fn startup_sequence_with_temp_db(db_name string, run fn (string)) {
	with_temp_sqlite_db_env('CODEXBOT_TS_DB_PATH', db_name, run)
}

fn test_inproc_vjsx_startup_sequence_app_startup_command_then_repo_boot() {
	temp_dir := os.join_path(os.temp_dir(), 'vhttpd_vjsx_startup_sequence_test')
	os.mkdir_all(temp_dir) or { panic(err) }
	app_file := os.join_path(temp_dir, 'app-startup-commands.mts')
	os.write_file(app_file, '
let appStartupCount = 0;

const app = {
  async app_startup(runtime) {
    appStartupCount += 1;
    const command = {};
    command.type = "provider.instance.upsert";
    command.provider = "demo";
    command.instance = "main";
    command.content = "{\\"value\\":\\"startup_value\\"}";
    command.metadata = { desired_state: "connected" };
    return { commands: [command] };
  },
  http(ctx) {
    return ctx.json({ appStartupCount }, 200);
  }
};

export default app;
') or {
		panic(err)
	}
	defer {
		os.rm(app_file) or {}
	}
	mut warm_executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count:    1
		app_entry:       app_file
		module_root:     temp_dir
		runtime_profile: 'node'
	})
	defer {
		warm_executor.close()
	}
	mut warm_app := App{
		feishu_apps:    map[string]FeishuAppConfig{}
		feishu_runtime: map[string]FeishuProviderRuntime{}
	}
	warm_executor.warmup(mut warm_app) or { panic(err) }
	spec := warm_app.provider_instance_get('demo', 'main') or { panic('missing provider instance spec') }
	assert spec.config_json.contains('"value":"startup_value"')

	startup_sequence_with_temp_db('codexbot_ts_startup_sequence.sqlite', fn (_ string) {
		repo_app_file := os.join_path(os.dir(@FILE), '..', 'examples', 'codexbot-app-ts', 'app.mts')
		assert os.exists(repo_app_file)
		mut repo_executor := new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			app_entry:       repo_app_file
			module_root:     os.dir(repo_app_file)
			runtime_profile: 'node'
		})
		defer {
			repo_executor.close()
		}
		mut repo_app := App{}
		resp := repo_executor.dispatch_websocket_upstream(mut repo_app,
			WorkerWebSocketUpstreamDispatchRequest{
				mode:        'websocket_upstream'
				event:       'message'
				id:          'codexbot_ts_startup_sequence'
				provider:    'feishu'
				instance:    'main'
				trace_id:    'trace_codexbot_ts_startup_sequence'
				event_type:  'im.message.receive_v1'
				message_id:  'om_codexbot_ts_startup_sequence'
				target:      'chat_codexbot_ts_startup_sequence'
				target_type: 'chat_id'
				payload:     startup_sequence_feishu_payload('/help', 'chat_codexbot_ts_startup_sequence',
					'om_codexbot_ts_startup_sequence')
				received_at: 1710002000
			}) or { panic(err) }
		assert resp.handled
		assert resp.commands.len > 0
	})
}
