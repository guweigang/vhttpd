module feishu

import time

fn stream_operation_fixture(mut s FeishuState) StreamCommand {
	s.register_stream_buffer('message', 'stream', 'main', 'chat', 'chat_id', 'old')
	return s.admit_wire_stream_command('message', 'stream', 'main', s.buffers['message'].generation) or { panic('admission') }
}

fn test_bridge_stream_operation_serializes_admission_and_fences_old_async_publishers() {
	mut s := FeishuState{}
	cmd := stream_operation_fixture(mut s)
	before := s.buffer_snapshot('message') or { panic('snapshot') }
	op := s.begin_bridge_stream_operation(cmd, false) or { panic('op') }
	assert s.begin_bridge_stream_operation(cmd, false) == none
	assert s.admit_wire_stream_command('message', 'stream', 'main', op.buffer.generation) == none
	assert s.admit_stream_command('message', 'stream', 'main') == none
	assert !s.commit_buffer_preview(before, 'late', 100)
	assert s.append_buffer_patch('message', 'main', 'late') == none
	assert s.buffers['message'].content == 'old'
	assert s.pending_buffer_snapshots(9999999999999).len == 0
	assert s.complete_bridge_stream_operation_unlocked(op, 'append', op.source.generation, 'open')
	assert s.admit_wire_stream_command('message', 'stream', 'main', op.buffer.generation) != none
	assert s.pending_buffer_snapshots(9999999999999).len == 0
	assert !s.buffer_snapshot_is_current(s.buffer_snapshot('message') or { panic('mirror') })
	assert !s.complete_bridge_stream_operation_unlocked(op, 'append', op.source.generation, 'open')
	assert !s.commit_buffer_preview(before, 'late', 100)
}

fn test_bridge_stream_completion_rejects_clear_rebind_and_recreate_without_touching_successor() {
	for action in ['append', 'finish', 'fail'] {
		for mode in ['clear', 'rebind', 'recreate'] {
			mut s := FeishuState{}
			cmd := stream_operation_fixture(mut s)
			op := s.begin_bridge_stream_operation(cmd, false) or { panic('op') }
			if mode in ['clear', 'recreate'] { s.clear_buffer('message') }
			if mode != 'clear' {
				s.register_stream_buffer('message', 'next', 'main', '', '', 'keep')
			}
			assert !s.complete_bridge_stream_operation_unlocked(op, action, op.source.generation, if action == 'fail' {
				'removed'
			} else {
				'sealed'
			})
			assert s.abort_bridge_stream_operation_unlocked(op) == none
			if mode == 'clear' {
				assert s.buffers.len == 0
			} else {
				assert s.buffers['message'].content == 'keep' && !s.buffers['message'].sealed
			}
		}
	}
}

fn test_bridge_stream_completion_validates_generation_and_action_state() {
	mut s := FeishuState{}
	cmd := stream_operation_fixture(mut s)
	op := s.begin_bridge_stream_operation(cmd, false) or { panic('op') }
	for generation in ['', 'wrong'] {
		assert !s.complete_bridge_stream_operation_unlocked(op, 'finish', generation, 'sealed')
	}
	assert !s.complete_bridge_stream_operation_unlocked(op, 'finish', op.source.generation, 'removed')
	assert !s.complete_bridge_stream_operation_unlocked(op, 'fail', op.source.generation, 'sealed')
	assert s.complete_bridge_stream_operation_unlocked(op, 'finish', op.source.generation, 'sealed')
	assert s.buffers['message'].sealed && s.buffers['message'].content == ''
	assert s.abort_bridge_stream_operation_unlocked(op) == none
}

fn test_bridge_stream_finish_preview_preserves_open_mirror_and_fail_withdraws_exact_generation() {
	mut s := FeishuState{}
	cmd := stream_operation_fixture(mut s)
	op := s.begin_bridge_stream_operation(cmd, false) or { panic('op') }
	assert s.complete_bridge_stream_operation_unlocked(op, 'finish', op.source.generation, 'open')
	assert !s.buffers['message'].sealed
	current := s.admit_wire_stream_command('message', 'stream', 'main', op.buffer.generation) or { panic('current') }
	failure := s.begin_bridge_stream_operation(current, false) or { panic('failure') }
	assert s.complete_bridge_stream_operation_unlocked(failure, 'fail', failure.source.generation, 'removed')
	assert s.abort_bridge_stream_operation_unlocked(failure) != none
	assert s.buffers.len == 0
}

fn test_bridge_stream_operation_disconnect_and_expiry_reject_late_receipt() {
	for retire in [false, true] {
		mut s := FeishuState{}
		mut owner := new_bridge_authority()
		_ := stream_operation_fixture(mut s)
		s.retain_bridge_binding_unlocked('message', BridgeBinding{ owner: owner, generation: s.buffers['message'].generation, stream: 'stream', app: 'main' })
		cmd := s.admit_wire_stream_command('message', 'stream', 'main', s.buffers['message'].generation) or { panic('cmd') }
		op := s.begin_bridge_stream_operation(cmd, false) or { panic('op') }
		if retire { _ := s.retire_bridge_authority_unlocked(mut owner) } else { owner.deadline = 1 }
		assert !s.complete_bridge_stream_operation_unlocked(op, 'finish', op.source.generation, 'sealed')
		_ := s.abort_bridge_stream_operation_unlocked(op)
		assert s.buffers.len == 0
	}
}

fn test_stream_failure_release_includes_only_identity_linked_successor_chain() {
	mut s := FeishuState{}
	_ := stream_operation_fixture(mut s)
	s.buffers['message'].sealed = true
	claim := s.append_buffer_patch('message', 'main', 'tail') or { panic('rollover') }
	assert s.commit_buffer_rollover(claim, 'child', 100)
	s.register_stream_buffer('peer', 'stream', 'main', '', '', 'keep')
	cmd := s.admit_stream_command('message', 'stream', 'main') or { panic('cmd') }
	failure := s.begin_stream_failure(cmd) or { panic('fail') }
	released := s.finish_stream_failure_release_unlocked(failure) or { panic('release') }
	assert released.message_ids == ['message', 'child']
	assert s.buffers.len == 1 && s.buffers['peer'].content == 'keep'
}

fn test_bridge_stream_receipt_cannot_unseal_an_already_sealed_generation() {
	mut s := FeishuState{}
	_ := stream_operation_fixture(mut s)
	s.buffers['message'].sealed = true
	cmd := s.admit_stream_command('message', 'stream', 'main') or { panic('cmd') }
	op := s.begin_bridge_stream_operation(cmd, false) or { panic('op') }
	assert !s.complete_bridge_stream_operation_unlocked(op, 'append', op.source.generation, 'open')
	assert s.complete_bridge_stream_operation_unlocked(op, 'append', op.source.generation, 'sealed')
	assert s.buffers['message'].sealed
}

fn test_bridge_stream_waiter_revalidates_original_gate_after_withdrawal_and_rebind() {
	for mode in ['clear', 'rebind', 'disconnect'] {
		mut s := &FeishuState{}
		_ := stream_operation_fixture(mut s)
		mut owner := new_bridge_authority()
		generation := s.buffers['message'].generation
		s.retain_bridge_binding_unlocked('message', BridgeBinding{ owner: owner, generation: generation, stream: 'stream', app: 'main' })
		lease := s.acquire_bridge_stream_gate('message', 'stream', 'main', generation) or { panic('first') }
		started := chan bool{cap: 1}
		done := chan bool{cap: 1}
		waiter := spawn fn [mut s, generation, started, done] () {
			started <- true
			if late := s.acquire_bridge_stream_gate('message', 'stream', 'main', generation) {
				late.release()
				done <- true
			} else {
				done <- false
			}
		}()
		_ = <-started
		select {
			_ := <-done {
				panic('waiter escaped held gate')
			}
			20 * time.millisecond {
			}
		}
		if mode == 'clear' { s.clear_buffer('message') }
		if mode == 'disconnect' { _ := s.retire_bridge_authority_unlocked(mut owner) }
		if mode == 'rebind' {
			s.register_stream_buffer('message', 'stream', 'main', '', '', 'keep')
			current := s.acquire_bridge_stream_gate('message', 'stream', 'main', s.buffers['message'].generation) or { panic('new gate blocked') }
			current.release()
		}
		lease.release()
		select {
			admitted := <-done {
				assert !admitted
			}
			3 * time.second {
				panic('waiter stuck')
			}
		}
		waiter.wait()
		if mode == 'rebind' {
			assert s.buffers['message'].content == 'keep'
		}
	}
}
