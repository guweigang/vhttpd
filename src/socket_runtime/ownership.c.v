module socket_runtime

import net

// Cancellation owns an alias, never a borrowed descriptor that could be reused.
pub fn retain(fd int) !int {
	owned := duplicate(fd)!
	protect(fd) or {
		net.close(owned) or {}
		return err
	}
	return owned
}
