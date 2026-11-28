module relay

// Captured while accepting OPEN under the channel mutex. Copies cannot adopt
// a later OPEN merely because the peer reused a public channel/frame ID.
pub struct InboundLease {
	channel_id   string
	registration ?&ChannelRegistration
}

pub fn (mut rt Runtime) finish_inbound_delivery(lease InboundLease) bool {
	expected := lease.registration or { return false }
	rt.channels.mu.@lock()
	defer { rt.channels.mu.unlock() }
	channel := rt.channels.channels[lease.channel_id] or { return false }
	current := channel.registration or { return false }
	if voidptr(expected) != voidptr(current) { return false }
	return rt.channels.retire_channel_unlocked(lease.channel_id)
}
