module executor

import json
import upstream.transport
import vjsx

struct InProcVjsxStartupResult {
	commands []transport.WorkerWebSocketUpstreamCommand
}

struct InProcVjsxStartupCodec {}

fn InProcVjsxStartupCodec.commands_from_js_value(val vjsx.Value) []transport.WorkerWebSocketUpstreamCommand {
	raw := val.json_stringify()
	if raw.trim_space() == '' || raw.trim_space() == 'undefined' || raw.trim_space() == 'null' {
		return []transport.WorkerWebSocketUpstreamCommand{}
	}
	normalized := json.decode(InProcVjsxStartupResult, raw) or { InProcVjsxStartupResult{} }
	return normalized.commands
}

fn InProcVjsxStartupCodec.request_id(kind string, lane_id string) string {
	return 'vjsx.${kind}.${lane_id}'
}

fn InProcVjsxStartupCodec.path(kind string) string {
	return '/__vhttpd/${kind}'
}

fn InProcVjsxStartupCodec.method(kind string) string {
	return kind.to_upper()
}
