module main

import feishu
import json2 as json
import net
import time

fn feishu_test_read_wire_bytes(mut peer net.TcpConn, size int) []u8 {
	mut bytes := []u8{len: size}
	mut count := 0
	for count < size {
		n := peer.read(mut bytes[count..]) or { panic(err) }
		assert n > 0
		count += n
	}
	return bytes
}

// A pending entry exists BEFORE the sender acquires its write lease. Removing
// it at that point can legitimately cancel sending. A simulated reply must wait
// until the peer has actually received the complete request frame.
fn feishu_test_sent_request(mut bridge FeishuCardBridgeContext, mut peer net.TcpConn) string {
	peer.set_read_timeout(2500 * time.millisecond)
	header := feishu_test_read_wire_bytes(mut peer, 2)
	assert header[0] & 0x0f == 1
	mut size := u64(header[1] & 0x7f)
	if size == 126 {
		ext := feishu_test_read_wire_bytes(mut peer, 2)
		size = (u64(ext[0]) << 8) | ext[1]
	} else if size == 127 {
		ext := feishu_test_read_wire_bytes(mut peer, 8)
		size = 0
		for byte in ext { size = (size << 8) | byte }
	}
	assert size > 0 && size <= 1024 * 1024
	mask := if header[1] & 0x80 != 0 { feishu_test_read_wire_bytes(mut peer, 4) } else { []u8{} }
	mut payload := feishu_test_read_wire_bytes(mut peer, int(size))
	if mask.len > 0 {
		for i in 0 .. payload.len { payload[i] ^= mask[i % 4] }
	}
	request := json.decode[feishu.BridgeProxyRequest](payload.bytestr()) or { panic(err) }
	assert request.request_id != ''
	bridge.state.card_bridge_mu.@lock()
	present := request.request_id in bridge.state.card_bridge_proxy_pending
	bridge.state.card_bridge_mu.unlock()
	assert present
	return request.request_id
}
