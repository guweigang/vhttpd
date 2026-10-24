module feishu

// A producer reserves this opaque publication ID before sending a command.
// Each binding owns a fresh counter, shared by its physical segment chain.
@[heap]
struct SentPublication {
	id string
mut:
	sequence i64
}

pub struct SentReceipt {
pub:
	stream_id            string
	message_id           string
	stream_generation    string
	instance             string
	publication_id       string
	publication_sequence i64
}

// Caller holds mu through buffer/target publication and receipt capture. Neither
// delayed dispatch nor a reused message ID may look up successor authority.
pub fn (mut s FeishuState) start_sent_publication_unlocked(message_id string, publication_id string) {
	mut buf := s.buffers[message_id] or { return }
	buf.sent_publication = &SentPublication{ id: publication_id }
	s.buffers[message_id] = buf
}

pub fn (mut s FeishuState) next_sent_receipt_unlocked(buffer_id string, message_id string) SentReceipt {
	buf := s.buffers[buffer_id] or { return SentReceipt{} }
	mut publication := buf.sent_publication or { return SentReceipt{} }
	publication.sequence++
	return SentReceipt{
		stream_id:            buf.stream_id
		message_id:           message_id
		stream_generation:    buf.generation
		instance:             buf.app
		publication_id:       publication.id
		publication_sequence: publication.sequence
	}
}
