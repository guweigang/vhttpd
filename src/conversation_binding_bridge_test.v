module main

import conversation_binding
import feishu

fn test_bridge_release_can_use_a_non_codex_coordinator() {
	mut state := &feishu.FeishuState{}
	mut authority := feishu.new_bridge_authority()
	mut releases := &[]conversation_binding.Release{}
	mut bridge := FeishuCardBridgeContext{
		state: state
		release_binding: fn [mut releases] (release conversation_binding.Release) {
			releases << release
		}
	}
	state.mu.@lock()
	state.register_stream_buffer_unlocked('message', 'stream', 'main', '', '', '')
	state.mu.unlock()
	bridge.retire_authority(mut authority)
	assert releases.len == 0
	assert state.buffer_snapshot('message') != none
	bridge.release_binding(feishu.WireStreamRelease{
		stream_id: 'stream'
		generation: 'generation'
		message_ids: ['message']
		retire_route: true
	}.binding_release())
	assert releases.len == 1
	assert (*releases)[0].platform == 'feishu'
	assert (*releases)[0].generation == 'generation'
	assert (*releases)[0].retire_route
}
