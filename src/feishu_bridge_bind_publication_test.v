module main

import command
import executor as execmod
import feishu
import upstream.transport

@[heap]
struct BindPublicationHost {
	App
mut:
	remote       &feishu.FeishuState     = &feishu.FeishuState{}
	owner        &feishu.BridgeAuthority = feishu.new_bridge_authority()
	interruption string
	cancelled    int
	notified     int
	receipts     []feishu.SentReceipt
}

fn (mut h BindPublicationHost) command_feishu_bridge_enabled() bool { return true }

fn (mut h BindPublicationHost) command_feishu_bridge_bind(claim feishu.BridgeBind) !string {
	assert h.providers.feishu.admit_wire_stream_command(claim.message, claim.buffer.stream_id, claim.buffer.app, claim.buffer.generation) == none
	h.remote.mu.@lock()
	generation := h.remote.publish_bridge_bind_unlocked(h.owner, claim.message, claim.stream, claim.app,
		claim.expected, claim.source.stream, claim.source.app, claim.creation, claim.token) or { panic('remote CAS') }
	h.remote.mu.unlock()
	match h.interruption {
		'clear' {
			h.providers.feishu.mu.@lock()
			released := h.providers.feishu.release_wire_stream_unlocked(claim.message, claim.buffer.stream_id, claim.buffer.app, claim.buffer.generation) or { panic('release') }
			h.codex_release_feishu_targets(released)
			h.providers.feishu.mu.unlock()
		}
		'destination' {
			h.providers.feishu.register_stream_buffer('native-message', claim.stream, 'main', '', '', 'keep-destination')
		}
		'replace' {
			h.providers.feishu.register_stream_buffer(claim.message, 'replacement', 'main', '', '', 'keep')
		}
		'disconnect' {
			h.providers.feishu.mu.@lock()
			for released in h.providers.feishu.retire_bridge_authority_unlocked(mut h.owner) {
				h.codex_release_feishu_targets(released)
			}
			h.providers.feishu.mu.unlock()
			h.remote.mu.@lock()
			_ := h.remote.retire_bridge_authority_unlocked(mut h.owner)
			h.remote.mu.unlock()
		}
		else {}
	}
	return generation
}

fn (mut h BindPublicationHost) command_feishu_bridge_cancel_bind(claim feishu.BridgeBind, generation string) ! {
	h.cancelled++
	h.remote.mu.@lock()
	_ := h.remote.release_bridge_stream_unlocked(h.owner, claim.message, claim.stream, claim.app, generation)
	h.remote.mu.unlock()
}

fn (mut h BindPublicationHost) dispatch_feishu_message_sent(receipt feishu.SentReceipt) {
	h.notified++
	h.receipts << receipt
}

fn bind_publication_run(mut h BindPublicationHost, stream string, generation string, lease feishu.CreationLease) execmod.WebSocketUpstreamCommandActivity {
	mut handler := FeishuCommandHandler.new(mut h)
	cmd := transport.WorkerWebSocketUpstreamCommand{
		type_:       'session.bind'
		provider:    'feishu'
		instance:    'main'
		stream_id:   stream
		target:      'message'
		target_type: 'message_id'
		metadata:    {
			'stream_generation':   generation
			'publication_id':      if stream == 'old' { 'a'.repeat(64) } else { 'b'.repeat(64) }
			'creation_generation': lease.generation
			'creation_token':      lease.token
		}
	}
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handled, _ := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
	assert handled
	return activity
}

fn bind_publication_fixture() (&BindPublicationHost, feishu.CreationLease) {
	mut h := &BindPublicationHost{}
	lease := h.remote.issue_bridge_creation(mut h.owner, 'old', 'main', 'message', 'bind') or { panic(err) }
	issue := h.providers.feishu.begin_creation_issue_for_target('old', 'main', 'message') or { panic(err) }
	h.providers.feishu.complete_bridge_creation_issue(issue, lease, h.owner) or { panic(err) }
	h.providers.feishu.finish_creation_issue(issue)
	return h, lease
}

fn test_bridge_bind_command_publishes_same_generation_then_rebinds_receipt_and_target() {
	mut h, lease := bind_publication_fixture()
	first := bind_publication_run(mut h, 'old', '', lease)
	assert first.status == 'bound'
	assert first.stream_generation == h.remote.buffers['message'].generation
	assert h.codex_find_stream_targets('old')[0].stream_generation == first.stream_generation
	next := bind_publication_run(mut h, 'new', first.stream_generation, feishu.CreationLease{})
	assert next.status == 'bound'
	assert next.stream_generation != first.stream_generation
	assert next.stream_generation == h.remote.buffers['message'].generation
	assert h.codex_find_stream_targets('old').len == 0
	assert h.codex_find_stream_targets('new')[0].stream_generation == next.stream_generation
	assert h.notified == 2 && h.cancelled == 0
	assert h.receipts[0].publication_id == 'a'.repeat(64)
	assert h.receipts[1].publication_id == 'b'.repeat(64)
	assert h.receipts[0].stream_generation == first.stream_generation
	assert h.receipts[1].stream_generation == next.stream_generation
	assert h.receipts[0].publication_sequence == 1 && h.receipts[1].publication_sequence == 1
}

fn test_bridge_bind_command_late_result_cannot_publish_after_clear_replace_or_disconnect() {
	for mode in ['clear', 'replace', 'disconnect', 'destination'] {
		mut h, lease := bind_publication_fixture()
		first := bind_publication_run(mut h, 'old', '', lease)
		assert first.status == 'bound'
		h.interruption = mode
		next := bind_publication_run(mut h, 'new', first.stream_generation, feishu.CreationLease{})
		assert next.status == 'error'
		assert h.cancelled == 1
		assert h.remote.buffers.len == 0
		assert h.codex_find_stream_targets('new').len == 0
		assert h.notified == 1
		if mode == 'destination' {
			assert h.providers.feishu.buffers['native-message'].content == 'keep-destination'
		} else if mode == 'replace' {
			assert h.providers.feishu.buffers['message'].content == 'keep'
		} else {
			assert h.providers.feishu.buffers.len == 0
		}
	}
}
