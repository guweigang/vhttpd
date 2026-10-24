module main

import command
import executor as execmod
import feishu
import upstream
import upstream.transport
import json2 as json
import os
import time

@[heap]
struct SentPublicationHost {
	App
mut:
	receipts []feishu.SentReceipt
}

fn (mut h SentPublicationHost) dispatch_feishu_message_sent(receipt feishu.SentReceipt) {
	h.receipts << receipt
}

fn (mut _ SentPublicationHost) websocket_upstream_send(req upstream.UpstreamSendRequest) !upstream.UpstreamSendResult {
	return upstream.UpstreamSendResult{ ok: true, provider: 'feishu', instance: req.instance, message_id: 'physical' }
}

fn sent_publication_execute(mut h SentPublicationHost, cmd transport.WorkerWebSocketUpstreamCommand) execmod.WebSocketUpstreamCommandActivity {
	mut handler := FeishuCommandHandler.new(mut h)
	mut activity := execmod.WebSocketUpstreamCommandActivity{}
	handled, err := handler.execute(cmd, command.NormalizedCommand.from_worker_command(cmd), mut activity)
	assert handled && err == ''
	return activity
}

fn test_sent_publication_initial_send_captures_original_command_intent() {
	mut h := SentPublicationHost{}
	lease := h.providers.feishu.issue_wire_creation('initial', 'main') or { panic(err) }
	result := sent_publication_execute(mut h, transport.WorkerWebSocketUpstreamCommand{
		type_:        'provider.message.send'
		provider:     'feishu'
		instance:     'main'
		stream_id:    'initial'
		target:       'chat'
		target_type:  'chat_id'
		message_type: 'interactive'
		metadata:     {
			'stream_generation': lease.generation
			'creation_token':    lease.token
			'publication_id':    'a'.repeat(64)
		}
	})
	assert result.status == 'sent'
	assert h.receipts.len == 1
	assert h.receipts[0].publication_id == 'a'.repeat(64)
	assert h.receipts[0].stream_generation == lease.generation
	assert h.receipts[0].publication_sequence == 1
	h.providers.feishu.clear_stream_buffers('initial')
	h.providers.feishu.register_stream_buffer('physical', 'initial', 'other', '', '', '')
	assert h.receipts[0].instance == 'main'
	assert h.receipts[0].stream_generation == lease.generation
}

fn test_sent_publication_bind_rebind_rollover_and_php_wire_admission() {
	mut h := SentPublicationHost{}
	lease := h.providers.feishu.issue_wire_bind_creation('wire', 'main', 'physical') or { panic(err) }
	first := sent_publication_execute(mut h, transport.WorkerWebSocketUpstreamCommand{
		type_:       'session.bind'
		provider:    'feishu'
		instance:    'main'
		stream_id:   'wire'
		target:      'physical'
		target_type: 'message_id'
		metadata:    {
			'creation_generation': lease.generation
			'creation_token':      lease.token
			'publication_id':      'a'.repeat(64)
		}
	})
	assert first.status == 'bound'
	next := sent_publication_execute(mut h, transport.WorkerWebSocketUpstreamCommand{
		type_:       'session.bind'
		provider:    'feishu'
		instance:    'main'
		stream_id:   'wire'
		target:      'physical'
		target_type: 'message_id'
		metadata:    {
			'stream_generation': first.stream_generation
			'publication_id':    'b'.repeat(64)
		}
	})
	assert next.status == 'bound' && next.stream_generation != first.stream_generation
	assert h.receipts[0].publication_id == 'a'.repeat(64)
	assert h.receipts[1].publication_id == 'b'.repeat(64)
	assert h.receipts[0].publication_sequence == 1 && h.receipts[1].publication_sequence == 1
	// The runtime helper returns the receipt at the same commit boundary as Codex.
	h.providers.feishu.buffers['physical'].receive_id = 'chat'
	h.providers.feishu.buffers['physical'].receive_id_type = 'chat_id'
	h.providers.feishu.buffers['physical'].sealed = true
	claim := h.providers.feishu.append_buffer_patch('physical', 'main', 'next') or { panic('claim') }
	receipt := h.App.feishu_runtime_commit_rollover_receipt(claim, 'successor') or { panic('receipt') }
	assert receipt.publication_id == 'b'.repeat(64) && receipt.publication_sequence == 2
	assert receipt.stream_generation == next.stream_generation
	h.receipts << receipt
	file := os.join_path(os.temp_dir(), 'feishu-sent-wire-${time.now().unix_micro()}.json')
	defer { os.rm(file) or {} }
	os.write_file(file, json.encode(h.receipts, escape_unicode: true, time_as_unix: true)) or { panic(err) }
	result := os.execute('php tests/protocol/feishu-generation-receipt.php "${file}"')
	assert result.exit_code == 0, result.output
}

fn test_sent_publication_finish_receipt_uses_claim_owner_and_rejects_retired_claim() {
	mut app := &App{}
	app.providers.feishu.register_stream_buffer('root', 'stream', 'main', 'chat', 'chat_id', 'content')
	app.providers.feishu.mu.@lock()
	app.providers.feishu.start_sent_publication_unlocked('root', 'finish')
	initial := app.providers.feishu.next_sent_receipt_unlocked('root', 'root')
	app.providers.feishu.mu.unlock()
	captured := app.providers.feishu.buffer_snapshot('root') or { panic('snapshot') }
	claim := app.providers.feishu.begin_buffer_finish(captured) or { panic('claim') }
	receipt := app.feishu_runtime_publish_finish_segment_receipt(claim, 'tail') or { panic('receipt') }
	assert receipt.publication_id == initial.publication_id && receipt.publication_sequence == 2
	app.providers.feishu.register_stream_buffer('root', 'replacement', 'other', '', '', '')
	assert app.feishu_runtime_publish_finish_segment_receipt(claim, 'late') == none
	assert receipt.instance == 'main' && receipt.stream_id == 'stream'
}
