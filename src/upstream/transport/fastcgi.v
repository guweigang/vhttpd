module transport

import net.http
import net.unix
import log
import os

// FastCGI 协议常量
const fcgi_version_1 = u8(1)

const fcgi_begin_request = u8(1)
const fcgi_abort_request = u8(2)
const fcgi_end_request = u8(3)
const fcgi_params = u8(4)
const fcgi_stdin = u8(5)
const fcgi_stdout = u8(6)
const fcgi_stderr = u8(7)
const fcgi_data = u8(8)

const fcgi_responder = u16(1)

pub struct FastCgiRecord {
pub mut:
	version        u8 = fcgi_version_1
	@type          u8
	request_id     u16 = 1
	content_length u16
	padding_length u8
	content        []u8
}

// 写入 16 位大端序
fn write_u16_be(mut buf []u8, val u16) {
	buf << u8(val >> 8)
	buf << u8(val & 0xFF)
}

// 读取 16 位大端序
fn read_u16_be(buf []u8, offset int) u16 {
	return (u16(buf[offset]) << 8) | u16(buf[offset + 1])
}

// 写入 Name-Value 长度对
fn write_nv_length(mut buf []u8, len int) {
	if len < 128 {
		buf << u8(len)
	} else {
		buf << u8(((len >> 24) & 0x7F) | 0x80)
		buf << u8((len >> 16) & 0xFF)
		buf << u8((len >> 8) & 0xFF)
		buf << u8(len & 0xFF)
	}
}

// 编码一个 FastCGI Record
pub fn (r FastCgiRecord) encode() []u8 {
	mut buf := []u8{}
	buf << r.version
	buf << r.@type
	write_u16_be(mut buf, r.request_id)
	write_u16_be(mut buf, r.content_length)
	buf << r.padding_length
	buf << u8(0) // reserved

	if r.content.len > 0 {
		buf << r.content.clone()
	}
	if r.padding_length > 0 {
		for _ in 0 .. r.padding_length {
			buf << u8(0)
		}
	}
	return buf
}

pub struct FastCgiCodec {}

// 编码一个完整的 FastCGI 请求
pub fn FastCgiCodec.encode_request(method string, path string, original_path string, req http.Request, remote_addr string, trace_id string, request_id string, env_overrides map[string]string) []u8 {
	mut buf := []u8{}

	// 1. FCGI_BEGIN_REQUEST
	mut begin_content := []u8{}
	write_u16_be(mut begin_content, fcgi_responder)
	begin_content << u8(0) // flags: 0 (FCGI_KEEP_CONN = 0)
	for _ in 0 .. 5 {
		begin_content << u8(0) // reserved
	}

	r_begin := FastCgiRecord{
		@type:          fcgi_begin_request
		content_length: u16(begin_content.len)
		content:        begin_content
	}
	buf << r_begin.encode()

	// 2. FCGI_PARAMS
	mut params_buf := []u8{}
	normalized_path, query_str := normalize_request_target_for_cgi(path)

	// 组装标准的 CGI 环境变量
	mut envs := map[string]string{}
	envs['REQUEST_METHOD'] = method.to_upper()

	// 针对 WordPress 解析物理 SCRIPT_FILENAME 路径
	wp_root := env_overrides['VPHP_WP_ROOT']
	mut script_filename := ''
	mut resolved_uri := normalized_path
	if wp_root != '' {
		mut rel_path := normalized_path
		idx := env_overrides['VHTTPD_INDEX']
		index_file := if idx != '' { idx } else { 'index.php' }
		if rel_path == '' || rel_path == '/' {
			rel_path = '/' + index_file
		}
		script_filename = wp_root.trim_right('/') + '/' + rel_path.trim_left('/')
		if os.is_dir(script_filename) {
			rel_path = os.join_path(rel_path, index_file)
			script_filename = os.join_path(script_filename, index_file)
		}
		resolved_uri = rel_path
	} else {
		script_filename = normalized_path
	}

	envs['SCRIPT_FILENAME'] = script_filename
	envs['DOCUMENT_ROOT'] = wp_root

	envs['REQUEST_URI'] = if original_path != '' { original_path } else { path }
	envs['DOCUMENT_URI'] = resolved_uri
	envs['SCRIPT_NAME'] = resolved_uri
	envs['QUERY_STRING'] = query_str
	envs['REMOTE_ADDR'] = if remote_addr != '' { remote_addr } else { '127.0.0.1' }
	envs['SERVER_SOFTWARE'] = 'vhttpd'
	envs['GATEWAY_INTERFACE'] = 'CGI/1.1'
	envs['SERVER_PROTOCOL'] = 'HTTP/1.1'
	scheme := req.header.get(.x_forwarded_proto) or { 'http' }
	envs['REQUEST_SCHEME'] = scheme
	envs['HTTPS'] = if scheme == 'https' { 'on' } else { 'off' }

	// 传递 HTTP Headers (复用已有的 header 映射辅助函数)
	req_headers := header_map_from_request(req)
	for header_key, header_val in req_headers {
		key := 'HTTP_' + header_key.to_upper().replace('-', '_')
		envs[key] = header_val
	}
	// 特殊处理 Content-Type 和 Content-Length，CGI 规范里这两个不带 HTTP_ 前缀
	if ct := req.header.get(.content_type) {
		envs['CONTENT_TYPE'] = ct
	}
	if cl := req.header.get(.content_length) {
		envs['CONTENT_LENGTH'] = cl
	} else if method.to_upper() == 'POST' || method.to_upper() == 'PUT' {
		envs['CONTENT_LENGTH'] = '${req.data.len}'
	}

	// 合并环境覆盖变量（比如系统环境变量 VPHP_WP_ROOT 等）
	for k, v in env_overrides {
		if k.starts_with('HTTP_') || k == 'VPHP_WP_ROOT' || k == 'VHTTPD_APP' {
			continue
		}
		envs[k] = v
	}

	// 编码 Params 键值对
	for k, v in envs {
		log.info('[fastcgi] env: ${k} = ${v}')
		write_nv_length(mut params_buf, k.len)
		write_nv_length(mut params_buf, v.len)
		for ch in k {
			params_buf << u8(ch)
		}
		for ch in v {
			params_buf << u8(ch)
		}
	}

	// 发送所有的 params，如果超过 65535 字节，分帧发送
	mut offset := 0
	for offset < params_buf.len {
		mut chunk_len := params_buf.len - offset
		if chunk_len > 65535 {
			chunk_len = 65535
		}
		r_params := FastCgiRecord{
			@type:          fcgi_params
			content_length: u16(chunk_len)
			content:        params_buf[offset..offset + chunk_len].clone()
		}
		buf << r_params.encode()
		offset += chunk_len
	}

	// 发送空的 params 帧，表示 params 结束
	r_params_end := FastCgiRecord{
		@type:          fcgi_params
		content_length: 0
	}
	buf << r_params_end.encode()

	// 3. FCGI_STDIN
	// 如果有 Request Body
	req_body := req.data
	if req_body.len > 0 {
		mut body_offset := 0
		for body_offset < req_body.len {
			mut chunk_len := req_body.len - body_offset
			if chunk_len > 65535 {
				chunk_len = 65535
			}
			mut chunk_content := []u8{}
			for i in 0 .. chunk_len {
				chunk_content << u8(req_body[body_offset + i])
			}
			r_stdin := FastCgiRecord{
				@type:          fcgi_stdin
				content_length: u16(chunk_len)
				content:        chunk_content
			}
			buf << r_stdin.encode()
			body_offset += chunk_len
		}
	}

	// 发送空的 stdin 帧，表示 stdin 结束
	r_stdin_end := FastCgiRecord{
		@type:          fcgi_stdin
		content_length: 0
	}
	buf << r_stdin_end.encode()

	return buf
}

// 辅助读取网络流确保读满指定的长度
fn read_full_from_stream(mut conn unix.StreamConn, bytes_to_read int) ![]u8 {
	mut out := []u8{len: bytes_to_read}
	mut read := 0
	for read < bytes_to_read {
		n := conn.read(mut out[read..])!
		if n <= 0 {
			return error('unexpected EOF')
		}
		read += n
	}
	return out
}

// 解析从 php-cgi socket 读取到的全部响应
pub fn FastCgiCodec.decode_response(mut conn unix.StreamConn) !WorkerResponse {
	mut stdout_buf := []u8{}
	mut stderr_buf := []u8{}

	for {
		// 1. 读取 8 字节头部
		header_bytes := read_full_from_stream(mut conn, 8) or {
			return error('read record header failed: ${err.msg()}')
		}

		rec_type := header_bytes[1]
		content_len := read_u16_be(header_bytes, 4)
		padding_len := header_bytes[6]

		// 2. 读取 content 数据
		mut content_bytes := []u8{}
		if content_len > 0 {
			content_bytes = read_full_from_stream(mut conn, int(content_len)) or {
				return error('read record content failed: ${err.msg()}')
			}
		}

		// 3. 读取 padding 数据并丢弃
		if padding_len > 0 {
			_ := read_full_from_stream(mut conn, int(padding_len)) or {
				return error('read record padding failed: ${err.msg()}')
			}
		}

		// 4. 根据类型处理
		match rec_type {
			fcgi_stdout {
				stdout_buf << content_bytes
			}
			fcgi_stderr {
				stderr_buf << content_bytes
			}
			fcgi_end_request {
				// 结束帧，退出读取循环
				break
			}
			else {}
		}
	}

	if stderr_buf.len > 0 {
		log.warn('[fastcgi] stderr from php-cgi: ' + stderr_buf.bytestr())
	}

	// 5. 解析 HTTP 响应头和 body
	return parse_http_response_from_cgi(stdout_buf.bytestr())!
}

// 解析 php-cgi 返回的包含 HTTP 头部和 Body 的内容
fn parse_http_response_from_cgi(raw_stdout string) !WorkerResponse {
	if raw_stdout == '' {
		return error('empty response from php-cgi')
	}

	mut parts_found := false
	mut header_part := ''
	mut body_part := ''
	if raw_stdout.contains('\r\n\r\n') {
		header_part, body_part = raw_stdout.split_once('\r\n\r\n') or { '', '' }
		parts_found = true
	} else if raw_stdout.contains('\n\n') {
		header_part, body_part = raw_stdout.split_once('\n\n') or { '', '' }
		parts_found = true
	}
	if !parts_found {
		return error('invalid cgi response format')
	}

	header_lines := header_part.split('\n')
	body := body_part

	mut status := 200
	mut headers := map[string]string{}

	for line in header_lines {
		trimmed := line.trim_space()
		if trimmed == '' {
			continue
		}
		k, v := trimmed.split_once(':') or { continue }
		key := k.trim_space()
		val := v.trim_space()

		if key.to_lower() == 'status' {
			status_parts := val.split(' ')
			if status_parts.len > 0 {
				status = status_parts[0].int()
			}
		} else if key.to_lower() == 'set-cookie' {
			if 'set-cookie' in headers {
				headers['set-cookie'] = headers['set-cookie'] + '\n' + val
			} else {
				headers['set-cookie'] = val
			}
		} else {
			headers[key.to_lower()] = val
		}
	}

	return WorkerResponse{
		id:      ''
		status:  status
		body:    body
		headers: headers
	}
}

// 辅助函数
fn normalize_request_target_for_cgi(path string) (string, string) {
	if !path.contains('?') {
		return path, ''
	}
	p1, p2 := path.split_once('?') or { return path, '' }
	return p1, p2
}
