module protocol

import net

pub fn Session.extract_client_capabilities_json(raw string) string {
	field_marker := '"capabilities"'
	mut idx := raw.index(field_marker) or { return '' }
	idx += field_marker.len
	for idx < raw.len && (raw[idx] == `:` || raw[idx] == ` ` || raw[idx] == `\n`
		|| raw[idx] == `\r` || raw[idx] == `\t`) {
		idx++
	}
	if idx >= raw.len || raw[idx] != `{` {
		return ''
	}
	start := idx
	mut depth := 0
	mut in_string := false
	mut escaped := false
	for i := idx; i < raw.len; i++ {
		ch := raw[i]
		if escaped {
			escaped = false
			continue
		}
		if ch == `\\` {
			if in_string {
				escaped = true
			}
			continue
		}
		if ch == `"` {
			in_string = !in_string
			continue
		}
		if in_string {
			continue
		}
		if ch == `{` {
			depth++
			continue
		}
		if ch == `}` {
			depth--
			if depth == 0 {
				return raw[start..i + 1]
			}
		}
	}
	return ''
}

pub fn Session.write_sse_json(mut conn net.TcpConn, raw string) bool {
	conn.write_string('event: message\ndata: ${raw}\n\n') or { return false }
	return true
}
