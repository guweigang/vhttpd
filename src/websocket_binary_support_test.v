module main

import encoding.base64
import net.websocket
import ws

fn test_websocket_dispatch_payload_from_message_supports_text_frame() {
	msg := websocket.Message{
		opcode: .text_frame
		payload: 'hello'.bytes()
	}
	opcode, payload, supported := websocket_dispatch_payload_from_message(&msg)
	assert supported
	assert opcode == 'text'
	assert payload == 'hello'
}

fn test_websocket_dispatch_payload_from_message_supports_binary_frame() {
	raw := [u8(0), 1, 2, 255]
	msg := websocket.Message{
		opcode: .binary_frame
		payload: raw.clone()
	}
	opcode, payload, supported := websocket_dispatch_payload_from_message(&msg)
	assert supported
	assert opcode == 'binary'
	assert payload == base64.encode(raw)
}

fn test_websocket_dispatch_payload_from_message_rejects_control_frame() {
	msg := websocket.Message{
		opcode: .ping
		payload: 'ping'.bytes()
	}
	opcode, payload, supported := websocket_dispatch_payload_from_message(&msg)
	assert !supported
	assert opcode == ''
	assert payload == ''
}

fn test_websocket_hub_payload_bytes_supports_text() {
	payload, code := ws.HubPendingMessage{data: 'hello', opcode: 'text'}.payload_bytes() or { panic('missing_payload') }
	assert code == websocket.OPCode.text_frame
	assert payload == 'hello'.bytes()
}

fn test_websocket_hub_payload_bytes_supports_binary() {
	raw := [u8(9), 8, 7, 6]
	payload, code := ws.HubPendingMessage{data: base64.encode(raw), opcode: 'binary'}.payload_bytes() or {
		panic('missing payload')
	}
	assert code == websocket.OPCode.binary_frame
	assert payload == raw
}

fn test_websocket_hub_payload_bytes_rejects_unknown_opcode() {
	_, _ := ws.HubPendingMessage{data: 'hello', opcode: 'pong'}.payload_bytes() or {
		assert true
		return
	}
	assert false
}
