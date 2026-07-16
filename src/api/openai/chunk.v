module openai

// ChunkDecodeState tracks incremental HTTP chunked-transfer decoding.
pub struct ChunkDecodeState {
pub mut:
	mode            string = 'unknown'
	buffer          string
	remaining       int
	need_chunk_crlf bool
	done            bool
}

// decode incrementally decodes an HTTP progress callback
// chunk. Handles auto-detection of plain vs chunked transfer encoding and
// returns the decoded accumulated content as a string.
pub fn (mut decoder ChunkDecodeState) decode(chunk []u8) string {
	if chunk.len == 0 || decoder.done {
		return ''
	}
	incoming := chunk.bytestr()
	if decoder.mode == 'plain' {
		return incoming
	}
	decoder.buffer += incoming
	if decoder.mode == 'unknown' {
		if decoder.buffer.contains('\r\n') {
			first_line := decoder.buffer.all_before('\r\n')
			_ := OpenAIResolvedPlan.hex_chunk_size(first_line) or {
				decoder.mode = 'plain'
				out := decoder.buffer
				decoder.buffer = ''
				return out
			}
			decoder.mode = 'chunked'
		} else if decoder.buffer.contains('\n') || decoder.buffer.len > 64 {
			decoder.mode = 'plain'
			out := decoder.buffer
			decoder.buffer = ''
			return out
		} else {
			return ''
		}
	}
	mut out := ''
	for decoder.mode == 'chunked' && decoder.buffer.len > 0 && !decoder.done {
		if decoder.need_chunk_crlf {
			if decoder.buffer.len < 2 {
				break
			}
			if decoder.buffer.starts_with('\r\n') {
				decoder.buffer = decoder.buffer[2..]
			} else if decoder.buffer.starts_with('\n') {
				decoder.buffer = decoder.buffer[1..]
			}
			decoder.need_chunk_crlf = false
		}
		if decoder.remaining == 0 {
			if !decoder.buffer.contains('\r\n') {
				break
			}
			line := decoder.buffer.all_before('\r\n')
			decoder.buffer = decoder.buffer.all_after('\r\n')
			size := OpenAIResolvedPlan.hex_chunk_size(line) or {
				decoder.mode = 'plain'
				out += decoder.buffer
				decoder.buffer = ''
				break
			}
			if size == 0 {
				decoder.done = true
				decoder.buffer = ''
				break
			}
			decoder.remaining = size
		}
		if decoder.remaining > 0 {
			take := if decoder.buffer.len < decoder.remaining {
				decoder.buffer.len
			} else {
				decoder.remaining
			}
			out += decoder.buffer[..take]
			decoder.buffer = decoder.buffer[take..]
			decoder.remaining -= take
			if decoder.remaining == 0 {
				decoder.need_chunk_crlf = true
			}
		}
	}
	return out
}
