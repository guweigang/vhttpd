module main

import os
import json

fn codexbot_ts_feishu_payload(text string, chat_id string, message_id string) string {
	content_json := json.encode({
		'text': text
	})
	return '{"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","content":${json.encode(content_json)}}}}'
}

fn codexbot_ts_feishu_thread_payload(text string, chat_id string, message_id string, root_id string, parent_id string) string {
	content_json := json.encode({
		'text': text
	})
	return '{"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","root_id":"${root_id}","parent_id":"${parent_id}","content":${json.encode(content_json)}}}}'
}

fn codexbot_ts_feishu_payload_with_event(text string, chat_id string, message_id string, event_id string, create_time string) string {
	content_json := json.encode({
		'text': text
	})
	return '{"header":{"event_id":"${event_id}","event_type":"im.message.receive_v1"},"event":{"sender":{"sender_id":{"open_id":"ou_test_user"}},"message":{"message_id":"${message_id}","chat_id":"${chat_id}","message_type":"text","create_time":"${create_time}","content":${json.encode(content_json)}}}}'
}

fn codexbot_ts_with_temp_db(db_name string, run fn (string)) {
	with_temp_sqlite_db_env('CODEXBOT_TS_DB_PATH', db_name, run)
}

fn codexbot_ts_app_file() string {
	return os.real_path(os.join_path(os.dir(@FILE), '..', 'examples', 'codexbot-app-ts',
		'app.mts'))
}

fn codexbot_ts_command_by_type(commands []WorkerWebSocketUpstreamCommand, type_ string) WorkerWebSocketUpstreamCommand {
	for command in commands {
		if command.type_ == type_ {
			return command
		}
	}
	assert false, 'missing command type ${type_}'
	return WorkerWebSocketUpstreamCommand{}
}

fn codexbot_ts_first_stream_id(commands []WorkerWebSocketUpstreamCommand) string {
	for command in commands {
		if command.stream_id != '' {
			return command.stream_id
		}
	}
	return ''
}
