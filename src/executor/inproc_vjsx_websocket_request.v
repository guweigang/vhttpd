module executor

import net.urllib
import upstream.transport

struct InProcVjsxWebSocketRequest {}

fn InProcVjsxWebSocketRequest.target_from_frame(frame transport.WorkerWebSocketFrame) string {
	if frame.query.len == 0 {
		return frame.path
	}
	mut keys := frame.query.keys()
	keys.sort()
	mut parts := []string{cap: keys.len}
	for key in keys {
		parts << '${urllib.query_escape(key)}=${urllib.query_escape(frame.query[key] or { '' })}'
	}
	query := parts.join('&')
	if query == '' {
		return frame.path
	}
	return '${frame.path}?${query}'
}

fn InProcVjsxWebSocketRequest.server_map(frame transport.WorkerWebSocketFrame) map[string]string {
	mut server := map[string]string{}
	host_header := frame.headers['host'] or { '' }
	host_name, port := urllib.split_host_port(host_header)
	server['host'] = host_name
	server['port'] = port
	server['remote_addr'] = frame.remote_addr
	server['url'] = InProcVjsxWebSocketRequest.target_from_frame(frame)
	return server
}

fn InProcVjsxWebSocketRequest.scheme_from_frame(frame transport.WorkerWebSocketFrame) string {
	for key in ['x-forwarded-proto', 'x-scheme'] {
		if raw := frame.headers[key] {
			normalized := raw.trim_space().to_lower()
			if normalized != '' {
				return normalized
			}
		}
	}
	return 'ws'
}
