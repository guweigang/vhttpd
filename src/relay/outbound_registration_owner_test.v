module relay

fn owned_outbound() OutboundOutcome {
	return OutboundOutcome{
		action:     .ready
		relay_id:   'edge'
		trace_id:   'same-trace'
		frame_id:   'same-request'
		completion: ResponseCompletionPolicy{ mode: 'wait', timeout_ms: 1 }
		frame:      WireFrame{ kind: .open, id: 'same-request', channel_id: 'slot', trace_id: 'same-trace', correlation_id: 'same-correlation' }
	}
}

fn outbound_return() WireFrame {
	return WireFrame{ kind: .data, id: 'relay-response:same-request', channel_id: 'slot', trace_id: 'same-trace', exchange_kind: 'response', body: 'new-response' }
}

fn test_old_outbound_finish_preserves_identical_replacement_and_correlations() {
	mut rt := empty_runtime()
	old := owned_outbound()
	next := owned_outbound()
	assert rt.track_outbound_delivery(old, 4).action == .opened
	assert rt.track_outbound_delivery(next, 4).action == .opened
	assert rt.finish_outbound_delivery(old).action == .rejected
	assert 'slot' in rt.channels.channels
	assert rt.channels.correlations['same-correlation'] == 'slot'
	assert rt.finish_outbound_delivery(next).action == .closed
}

fn test_old_outbound_wait_does_not_consume_replacement_response() {
	mut rt := empty_runtime()
	old := owned_outbound()
	next := owned_outbound()
	rt.track_outbound_delivery(old, 4)
	rt.track_outbound_delivery(next, 4)
	rt.handle_frame(outbound_return(), 'edge', 4)
	sent := CarrierSendResult{ ok: true }
	assert rt.response_completion_after_send(old, sent).action != .completed
	current := rt.response_completion_after_send(next, sent)
	assert current.action == .completed
	assert current.delivery.body == 'new-response'
}

fn test_finished_outbound_cannot_finish_reused_channel_twice() {
	mut rt := empty_runtime()
	old := owned_outbound()
	rt.track_outbound_delivery(old, 4)
	assert rt.finish_outbound_delivery(old).action == .closed
	next := owned_outbound()
	rt.track_outbound_delivery(next, 4)
	assert rt.finish_outbound_delivery(old).action == .rejected
	assert rt.finish_outbound_delivery(next).action == .closed
}

fn test_untracked_outbound_has_no_channel_cleanup_authority() {
	mut rt := empty_runtime()
	registered := owned_outbound()
	rt.track_outbound_delivery(registered, 4)
	untracked := owned_outbound()
	assert rt.finish_outbound_delivery(untracked).action == .rejected
	assert rt.finish_outbound_delivery(registered).action == .closed
}

fn test_rejected_tracking_has_no_cleanup_authority() {
	mut rt := empty_runtime()
	registered := owned_outbound()
	rt.track_outbound_delivery(registered, 4)
	bad := OutboundOutcome{ ...owned_outbound(), frame: WireFrame{ ...owned_outbound().frame, correlation_id: ' ' } }
	assert rt.track_outbound_delivery(bad, 4).action == .rejected
	assert rt.finish_outbound_delivery(bad).action == .rejected
	assert rt.finish_outbound_delivery(registered).action == .closed
}

fn test_outbound_cannot_retrack_and_reacquire_a_replacement() {
	mut rt := empty_runtime()
	old := owned_outbound()
	next := owned_outbound()
	rt.track_outbound_delivery(old, 4)
	rt.track_outbound_delivery(next, 4)
	rt.handle_frame(outbound_return(), 'edge', 4)
	assert rt.track_outbound_delivery(old, 4).action == .rejected
	current := rt.response_completion_after_send(next, CarrierSendResult{ ok: true })
	assert current.action == .completed
	assert current.delivery.body == 'new-response'
}

fn test_matching_closed_channel_remains_owned_until_finish() {
	mut rt := empty_runtime()
	outbound := owned_outbound()
	rt.track_outbound_delivery(outbound, 4)
	assert rt.channels.close_channel('slot')
	assert rt.finish_outbound_delivery(outbound).action == .closed
	assert rt.channels.channels.len == 0
}

fn test_current_outbound_wait_consumes_own_response_then_releases() {
	mut rt := empty_runtime()
	outbound := owned_outbound()
	rt.track_outbound_delivery(outbound, 4)
	rt.handle_frame(outbound_return(), 'edge', 4)
	assert rt.response_completion_after_send(outbound, CarrierSendResult{ ok: true }).action == .completed
	assert rt.finish_outbound_delivery(outbound).action == .closed
}

fn test_registration_capability_is_scoped_to_its_runtime() {
	mut first := empty_runtime()
	mut second := empty_runtime()
	old := owned_outbound()
	next := owned_outbound()
	first.track_outbound_delivery(old, 4)
	second.track_outbound_delivery(next, 4)
	assert second.finish_outbound_delivery(old).action == .rejected
	assert first.finish_outbound_delivery(next).action == .rejected
	assert first.finish_outbound_delivery(old).action == .closed
	assert second.finish_outbound_delivery(next).action == .closed
}

fn test_stale_completion_is_atomic_with_concurrent_reopen_and_queue_admission() {
	mut rt := &Runtime{ ...empty_runtime() }
	old := owned_outbound()
	rt.track_outbound_delivery(old, 4)
	rt.channels.open_channel(RelayChannel{ id: 'slot', trace_id: 'replacement' }) or { panic(err) }
	writer := spawn fn [mut rt] () {
		for _ in 0 .. 100 {
			rt.channels.open_channel(RelayChannel{ id: 'slot', trace_id: 'replacement' }) or { panic(err) }
			rt.channels.enqueue('slot', outbound_return()) or { panic(err) }
			assert rt.snapshot().channel_count == 1
		}
	}()
	reader := spawn fn [mut rt, old] () {
		for _ in 0 .. 100 {
			assert rt.response_completion_after_send(old, CarrierSendResult{ ok: true }).action == .failed
			assert rt.finish_outbound_delivery(old).action == .rejected
		}
	}()
	writer.wait()
	reader.wait()
	assert rt.snapshot().channel_count == 1
	assert rt.snapshot().returned_frames == 1
}
