module feishu

import json
import net.urllib

// ── Protobuf Encoding ──

pub fn RuntimeProtoFrame.varint_encode(mut out []u8, value u64) {
	mut current := value
	for {
		if (current & ~u64(0x7f)) == 0 {
			out << u8(current)
			return
		}
		out << u8((current & 0x7f) | 0x80)
		current >>= 7
	}
}

pub fn RuntimeProtoFrame.encode_field_key(mut out []u8, field_number int, wire_type int) {
	RuntimeProtoFrame.varint_encode(mut out, (u64(field_number) << 3) | u64(wire_type))
}

pub fn RuntimeProtoFrame.encode_bytes_field(mut out []u8, field_number int, payload []u8) {
	RuntimeProtoFrame.encode_field_key(mut out, field_number, 2)
	RuntimeProtoFrame.varint_encode(mut out, u64(payload.len))
	out << payload
}

pub fn RuntimeProtoFrame.encode_string_field(mut out []u8, field_number int, payload string) {
	RuntimeProtoFrame.encode_bytes_field(mut out, field_number, payload.bytes())
}

pub fn (header RuntimeProtoHeader) encode() []u8 {
	mut out := []u8{}
	if header.key != '' {
		RuntimeProtoFrame.encode_string_field(mut out, 1, header.key)
	}
	if header.value != '' {
		RuntimeProtoFrame.encode_string_field(mut out, 2, header.value)
	}
	return out
}

pub fn (frame RuntimeProtoFrame) encode() []u8 {
	mut out := []u8{}
	if frame.seq_id > 0 {
		RuntimeProtoFrame.encode_field_key(mut out, 1, 0)
		RuntimeProtoFrame.varint_encode(mut out, frame.seq_id)
	}
	if frame.log_id > 0 {
		RuntimeProtoFrame.encode_field_key(mut out, 2, 0)
		RuntimeProtoFrame.varint_encode(mut out, frame.log_id)
	}
	if frame.service != 0 {
		RuntimeProtoFrame.encode_field_key(mut out, 3, 0)
		RuntimeProtoFrame.varint_encode(mut out, u64(frame.service))
	}
	RuntimeProtoFrame.encode_field_key(mut out, 4, 0)
	RuntimeProtoFrame.varint_encode(mut out, u64(frame.method))

	for header in frame.headers {
		encoded := header.encode()
		if encoded.len > 0 {
			RuntimeProtoFrame.encode_bytes_field(mut out, 5, encoded)
		}
	}
	if frame.payload_encoding != '' {
		RuntimeProtoFrame.encode_string_field(mut out, 6, frame.payload_encoding)
	}
	if frame.payload_type != '' {
		RuntimeProtoFrame.encode_string_field(mut out, 7, frame.payload_type)
	}
	if frame.payload.len > 0 {
		RuntimeProtoFrame.encode_bytes_field(mut out, 8, frame.payload)
	}
	if frame.log_id_str != '' {
		RuntimeProtoFrame.encode_string_field(mut out, 9, frame.log_id_str)
	}
	return out
}

// ── Protobuf Decoding ──

pub fn RuntimeProtoFrame.varint_decode(buf []u8, start int) !(u64, int) {
	mut value := u64(0)
	mut shift := 0
	mut idx := start
	for idx < buf.len {
		b := buf[idx]
		value |= u64(b & 0x7f) << shift
		idx++
		if (b & 0x80) == 0 {
			return value, idx
		}
		shift += 7
		if shift >= 64 {
			return error('protobuf varint overflow')
		}
	}
	return error('unexpected end of protobuf varint')
}

pub fn RuntimeProtoFrame.skip_wire(buf []u8, start int, wire_type int) !int {
	match wire_type {
		0 {
			_, next := RuntimeProtoFrame.varint_decode(buf, start)!
			return next
		}
		2 {
			length, next := RuntimeProtoFrame.varint_decode(buf, start)!
			end := next + int(length)
			if end > buf.len {
				return error('protobuf length exceeds payload')
			}
			return end
		}
		else {
			return error('unsupported protobuf wire type ${wire_type}')
		}
	}
}

pub fn RuntimeProtoHeader.decode(buf []u8) !RuntimeProtoHeader {
	mut out := RuntimeProtoHeader{}
	mut idx := 0
	for idx < buf.len {
		key, next := RuntimeProtoFrame.varint_decode(buf, idx)!
		idx = next
		field_number := int(key >> 3)
		wire_type := int(key & 0x07)
		if wire_type != 2 {
			idx = RuntimeProtoFrame.skip_wire(buf, idx, wire_type)!
			continue
		}
		length, next_len := RuntimeProtoFrame.varint_decode(buf, idx)!
		start := next_len
		end := start + int(length)
		if end > buf.len {
			return error('protobuf header payload truncated')
		}
		value := buf[start..end].bytestr()
		match field_number {
			1 { out.key = value }
			2 { out.value = value }
			else {}
		}

		idx = end
	}
	return out
}

pub fn RuntimeProtoFrame.decode(buf []u8) !RuntimeProtoFrame {
	mut out := RuntimeProtoFrame{}
	mut idx := 0
	for idx < buf.len {
		key, next := RuntimeProtoFrame.varint_decode(buf, idx)!
		idx = next
		field_number := int(key >> 3)
		wire_type := int(key & 0x07)
		match field_number {
			1, 2, 3, 4 {
				value, next_val := RuntimeProtoFrame.varint_decode(buf, idx)!
				match field_number {
					1 { out.seq_id = value }
					2 { out.log_id = value }
					3 { out.service = i32(value) }
					4 { out.method = i32(value) }
					else {}
				}

				idx = next_val
			}
			5, 6, 7, 8, 9 {
				if wire_type != 2 {
					return error('unexpected protobuf wire type ${wire_type} for field ${field_number}')
				}
				length, next_len := RuntimeProtoFrame.varint_decode(buf, idx)!
				start := next_len
				end := start + int(length)
				if end > buf.len {
					return error('protobuf field exceeds payload')
				}
				match field_number {
					5 {
						header := RuntimeProtoHeader.decode(buf[start..end])!
						out.headers << header
					}
					6 {
						out.payload_encoding = buf[start..end].bytestr()
					}
					7 {
						out.payload_type = buf[start..end].bytestr()
					}
					8 {
						out.payload = buf[start..end].clone()
					}
					9 {
						out.log_id_str = buf[start..end].bytestr()
					}
					else {}
				}

				idx = end
			}
			else {
				idx = RuntimeProtoFrame.skip_wire(buf, idx, wire_type)!
			}
		}
	}
	return out
}

pub fn RuntimeProtoHeader.to_map(headers []RuntimeProtoHeader) map[string]string {
	mut out := map[string]string{}
	for header in headers {
		if header.key == '' {
			continue
		}
		out[header.key] = header.value
	}
	return out
}

// ── Frame Helpers ──

pub fn (frame RuntimeProtoFrame) clone_headers_with_type(next_type string) []RuntimeProtoHeader {
	mut out_headers := []RuntimeProtoHeader{}
	mut found_type := false
	for header in frame.headers {
		if header.key == header_type {
			found_type = true
			out_headers << RuntimeProtoHeader{
				key:   header.key
				value: next_type
			}
			continue
		}
		out_headers << RuntimeProtoHeader{
			key:   header.key
			value: header.value
		}
	}
	if !found_type {
		out_headers << RuntimeProtoHeader{
			key:   header_type
			value: next_type
		}
	}
	return out_headers
}

pub fn (frame RuntimeProtoFrame) pong() RuntimeProtoFrame {
	return RuntimeProtoFrame{
		seq_id:           frame.seq_id
		log_id:           frame.log_id
		service:          frame.service
		method:           3
		headers:          frame.clone_headers_with_type(message_pong)
		payload_encoding: frame.payload_encoding
		payload_type:     frame.payload_type
		payload:          frame.payload.clone()
		log_id_str:       frame.log_id_str
	}
}

pub fn RuntimeProtoHeader.message_type(headers []RuntimeProtoHeader) string {
	for header in headers {
		if header.key == header_type && header.value.trim_space() != '' {
			return header.value
		}
	}
	return message_data
}

pub fn (frame RuntimeProtoFrame) ack(status int, headers_ map[string]string, data string) RuntimeProtoFrame {
	mut out_headers := frame.clone_headers_with_type(RuntimeProtoHeader.message_type(frame.headers))
	mut found_biz_rt := false
	for header in out_headers {
		if header.key == header_biz_rt {
			found_biz_rt = true
		}
	}
	if found_biz_rt {
		for i, header in out_headers {
			if header.key == header_biz_rt {
				out_headers[i].value = '0'
			}
		}
	} else {
		out_headers << RuntimeProtoHeader{
			key:   header_biz_rt
			value: '0'
		}
	}
	payload := json.encode(WsResponsePayload{
		code:    if status > 0 { status } else { 200 }
		headers: headers_.clone()
		data:    data
	})
	return RuntimeProtoFrame{
		seq_id:           frame.seq_id
		log_id:           frame.log_id
		service:          frame.service
		method:           frame_type_data
		headers:          out_headers
		payload_encoding: 'json'
		payload_type:     'application/json'
		payload:          payload.bytes()
		log_id_str:       frame.log_id_str
	}
}

pub fn RuntimeProtoFrame.service_id_from_ws_url(ws_url string) i32 {
	parsed := urllib.parse(ws_url) or { return 0 }
	service_id := (parsed.query().get('service_id') or { '' }).trim_space()
	if service_id == '' {
		return 0
	}
	return service_id.int()
}

pub fn RuntimeProtoFrame.client_ping(service_id i32) RuntimeProtoFrame {
	mut headers := []RuntimeProtoHeader{}
	headers << RuntimeProtoHeader{
		key:   header_type
		value: message_ping
	}
	return RuntimeProtoFrame{
		service: service_id
		method:  2
		headers: headers
	}
}
