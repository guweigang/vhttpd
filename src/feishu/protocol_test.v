module feishu

fn test_proto2_required_zero_fields_and_unknown_extension() {
	assert RuntimeProtoFrame{}.encode() == [u8(8), 0, 16, 0, 24, 0, 32, 0]
	mut bytes := RuntimeProtoFrame{}.encode()
	bytes << [u8(80), 1] // optional field 10 from a future server
	frame := RuntimeProtoFrame.decode(bytes) or { panic(err) }
	assert frame.seq_id == 0
	for invalid in [[]u8{}, [u8(8), 0], [u8(10), 0, 16, 0, 24, 0, 32, 0], [u8(8), 128]] {
		if _ := RuntimeProtoFrame.decode(invalid) {
			assert false
		}
	}
}

fn fragment(id string, seq string, text string) RuntimeProtoFrame {
	return RuntimeProtoFrame{ payload: text.bytes(), headers: [
		RuntimeProtoHeader{ key: 'message_id', value: id },
		RuntimeProtoHeader{ key: 'sum', value: '2' },
		RuntimeProtoHeader{ key: 'seq', value: seq },
	] }
}

fn test_fragments_reorder_deduplicate_and_isolate_instances() {
	mut owner := FragmentOwner{}
	assert !(owner.merge('a', fragment('m', '1', '}'), 0) or { panic(err) }).ready
	assert !(owner.merge('b', fragment('m', '0', 'other'), 0) or { panic(err) }).ready
	assert !(owner.merge('a', fragment('m', '1', '}'), 1) or { panic(err) }).ready
	result := owner.merge('a', fragment('m', '0', '{'), 2) or { panic(err) }
	assert result.ready && result.frame.payload.bytestr() == '{}'
	if _ := owner.merge('b', fragment('m', '0', 'conflict'), 2) {
		assert false
	}
	assert !(owner.merge('a', fragment('expired', '0', 'old'), 0) or { panic(err) }).ready
	assert !(owner.merge('a', fragment('expired', '1', 'new'), 60001) or { panic(err) }).ready
}

fn test_fragments_are_cleared_on_reconnect_and_proto_unknown_fixed_fields_are_tolerated() {
	mut owner := FragmentOwner{}
	owner.merge('a', fragment('m', '0', 'old'), 0) or { panic(err) }
	owner.clear('a')
	assert !(owner.merge('a', fragment('m', '1', 'new'), 1) or { panic(err) }).ready
	mut bytes := RuntimeProtoFrame{}.encode()
	bytes << [u8(85), 0, 0, 0, 0] // unknown fixed32 field 10
	RuntimeProtoFrame.decode(bytes) or { panic(err) }
	if _ := RuntimeProtoHeader.decode([u8(10), 1, `a`]) {
		assert false
	}
}
