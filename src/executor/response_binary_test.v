module executor

import vjsx

fn test_binary_http_response_codec_preserves_non_utf8_and_rejects_invalid_envelopes() {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	ctx := session.context()
	binary := ctx.eval('({status:201,bodyBase64:"AP+AQQ==",headers:{"content-type":"application/octet-stream"}})') or { panic(err) }
	defer { binary.free() }
	response := InProcVjsxResponseCodec.from_js_value(binary, 'binary-test')
	assert response.status == 201
	assert response.body.bytes() == [u8(0), 255, 128, 65]
	assert response.headers['content-type'] == 'application/octet-stream'
	for source in ['({bodyBase64:"invalid!"})', '({bodyBase64:123})'] {
		value := ctx.eval(source) or { panic(err) }
		assert InProcVjsxResponseCodec.from_js_value(value, 'bad').status == 500
		value.free()
	}
	text := ctx.eval('({body:"plain text"})') or { panic(err) }
	defer { text.free() }
	assert InProcVjsxResponseCodec.from_js_value(text, 'text').body == 'plain text'
}
