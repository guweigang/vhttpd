module feishu

fn test_sent_publication_snapshot_cannot_adopt_rebound_same_id_authority() {
	mut s := FeishuState{}
	s.register_stream_buffer('message', 'stream', 'instance', '', '', '')
	s.mu.@lock()
	s.start_sent_publication_unlocked('message', 'first')
	old := s.next_sent_receipt_unlocked('message', 'message')
	s.mu.unlock()
	s.register_stream_buffer('message', 'stream', 'instance', '', '', '')
	s.mu.@lock()
	assert s.next_sent_receipt_unlocked('message', 'message').publication_id == ''
	s.start_sent_publication_unlocked('message', 'second')
	next := s.next_sent_receipt_unlocked('message', 'message')
	s.mu.unlock()
	assert old.publication_id == 'first' && old.publication_sequence == 1
	assert next.publication_id == 'second' && next.publication_sequence == 1
	assert old.stream_generation != next.stream_generation
	assert old.instance == 'instance' && next.instance == 'instance'
}

fn test_sent_publication_sequence_is_shared_by_rollover_chain() {
	mut s := FeishuState{}
	s.register_stream_buffer('root', 'stream', 'main', 'chat', 'chat_id', 'content')
	s.mu.@lock()
	s.start_sent_publication_unlocked('root', 'publication')
	first := s.next_sent_receipt_unlocked('root', 'root')
	s.mu.unlock()
	s.buffers['root'].sealed = true
	claim := s.append_buffer_patch('root', 'main', 'next') or { panic('rollover') }
	assert s.commit_buffer_rollover(claim, 'next', 1000)
	s.mu.@lock()
	next := s.next_sent_receipt_unlocked('next', 'next')
	// A multi-segment finish from the same owner must not reset the counter.
	last := s.next_sent_receipt_unlocked('root', 'finish-segment')
	s.mu.unlock()
	assert first.publication_sequence == 1
	assert next.publication_sequence == 2 && last.publication_sequence == 3
	assert next.publication_id == first.publication_id
	assert next.stream_generation == first.stream_generation
	assert first.message_id == 'root' && last.message_id == 'finish-segment'
}

fn test_sent_publication_clear_before_recreate_does_not_restore_old_counter() {
	mut s := FeishuState{}
	s.register_stream_buffer('same', 'stream', 'main', '', '', '')
	s.mu.@lock()
	s.start_sent_publication_unlocked('same', 'old')
	captured := s.next_sent_receipt_unlocked('same', 'same')
	s.mu.unlock()
	s.clear_stream_buffers('stream')
	s.mu.@lock()
	assert s.next_sent_receipt_unlocked('same', 'same').stream_id == ''
	s.mu.unlock()
	s.register_stream_buffer('same', 'stream', 'main', '', '', '')
	s.mu.@lock()
	s.start_sent_publication_unlocked('same', 'fresh')
	fresh := s.next_sent_receipt_unlocked('same', 'same')
	s.mu.unlock()
	assert captured.publication_id == 'old'
	assert fresh.publication_id == 'fresh' && fresh.publication_sequence == 1
}
