module main

import feishu
import json2 as json
import encoding.hex
import os

struct Input {
	operation string
	response string
	hex       string
	frame     feishu.RuntimeProtoFrame
}

fn main() {
	input := json.decode[Input](os.get_raw_line()) or {
		eprintln('invalid test input')
		exit(1)
	}
	if input.operation == 'encode' {
		println(input.frame.encode().hex())
		return
	}
	bytes := hex.decode(input.hex) or {
		eprintln('invalid hex')
		exit(1)
	}
	frame := feishu.RuntimeProtoFrame.decode(bytes) or {
		eprintln('invalid protobuf')
		exit(1)
	}
	if input.operation == 'ack' {
		println(frame.ack(200, map[string]string{}, input.response).encode().hex())
		return
	}
	if input.operation == 'pong' {
		println(frame.pong().encode().hex())
		return
	}
	println(json.encode(frame))
}
