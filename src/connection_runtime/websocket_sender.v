module connection_runtime

import net.websocket
import sync
import time

// Construct on the connection's reader/registration thread before publication.
// Never copy a live reader's mutable buffers from an asynchronous sender.
@[heap]
pub struct WebSocketSender {
	template websocket.Client @[required]
pub:
	client &websocket.Client @[required]
mut:
	mu      sync.Mutex
	retired bool
	active  int
}

pub fn WebSocketSender.new(client &websocket.Client) &WebSocketSender {
	rlock client.client_state {
		mut template := *client
		fresh := websocket.Client{ client_state: websocket.ClientState{ state: .open } }
		// V3 struct-update of a shared field writes the old shared value instead
		// of replacing its reference. Copy only the compiler-derived pointer slot;
		// never copy a mutex or depend on a hard-coded Client layout. The template
		// keeps the original frame-write lock and TCP/TLS references.
		offset := __offsetof(websocket.Client, client_state)
		unsafe { vmemcpy(&u8(&template) + offset, &u8(&fresh) + offset, int(sizeof(voidptr))) }

		return &WebSocketSender{ client: unsafe { client }, template: template }
	}
}

pub fn (mut sender WebSocketSender) retire() {
	sender.mu.@lock()
	sender.retired = true
	sender.mu.unlock()
}

pub fn (mut sender WebSocketSender) wait_idle() {
	for {
		sender.mu.@lock()
		idle := sender.active == 0
		sender.mu.unlock()
		if idle { return }
		time.sleep(time.millisecond)
	}
}

// The native close path must acquire the original ClientState write lock to
// enter .closing before touching TCP/TLS. Keep a read lease over the whole write.
// The callback may only write; it must not close or re-enter the original owner.
// The immutable writer template has its own open state, avoiding recursive reads
// of the original state lock while a closer is waiting for exclusive access.
pub fn (mut sender WebSocketSender) with_lease(write_fn fn (mut websocket.Client) !) ! {
	sender.mu.@lock()
	if sender.retired {
		sender.mu.unlock()
		return error('websocket_sender_retired')
	}
	sender.active++
	sender.mu.unlock()
	defer {
		sender.mu.@lock()
		sender.active--
		sender.mu.unlock()
	}
	client := sender.client
	rlock client.client_state {
		if client.client_state.state != .open { return error('websocket_sender_closed') }
		if voidptr(client.conn) != voidptr(sender.template.conn) {
			return error('websocket_sender_generation_changed')
		}
		mut writer := sender.template
		write_fn(mut writer)!
	}
}

pub fn (mut sender WebSocketSender) write_string(payload string) ! {
	sender.with_lease(fn [payload] (mut writer websocket.Client) ! {
		writer.write_string(payload)!
	})!
}
